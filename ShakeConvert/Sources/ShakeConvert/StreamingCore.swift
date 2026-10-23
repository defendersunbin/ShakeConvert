import Foundation
import Compression

// 대용량 처리의 공통 부품: 스트리밍 압축/해제, 디스크 여유 보호, ZIP(ZIP64 포함) 읽기·쓰기

// MARK: - 오류 변환

extension ConvertError {
    /// 디스크가 가득 찬 경우는 "저장 공간이 부족합니다"로, 나머지는 저장 실패로 바꾼다.
    static func wrapping(_ error: Error) -> ConvertError {
        if let known = error as? ConvertError { return known }
        let ns = error as NSError
        let outOfSpace = (ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
        return outOfSpace ? .notEnoughSpace : .writeFailed(error.localizedDescription)
    }
}

// MARK: - 디스크 여유 보호

enum DiskGuard {
    /// 이 아래로 여유 공간이 줄면 디스크가 가득 차기 전에 깔끔하게 중단한다.
    static let headroom: Int64 = 128 << 20

    static func check(_ directory: URL) throws {
        guard let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        else { return } // 확인할 수 없으면 막지 않음
        if free < headroom { throw ConvertError.notEnoughSpace }
    }
}

// MARK: - 스트리밍 압축 / 해제 (zip이 쓰는 raw DEFLATE)

/// Apple Compression 프레임워크의 COMPRESSION_ZLIB는 raw DEFLATE(RFC 1951)이며 zip의 method 8과 같은 형식이다.
final class StreamCodec {
    enum Mode { case encode, decode }

    private static let bufferSize = 1 << 18
    private var stream: compression_stream
    private let out: UnsafeMutablePointer<UInt8>
    private var finished = false

    init(_ mode: Mode) throws {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
        var s = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        let operation = mode == .encode ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE
        guard compression_stream_init(&s, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            buffer.deallocate()
            throw ConvertError.readFailed
        }
        out = buffer
        stream = s
    }

    deinit {
        compression_stream_destroy(&stream)
        out.deallocate()
    }

    /// 입력을 넣고, 나온 출력 조각을 emit으로 넘긴다. 스트림이 끝났으면 true.
    /// 더 넣을 입력이 없을 때는 finalize를 true로 해서 마지막 호출을 한다.
    @discardableResult
    func process(_ input: Data, finalize: Bool, emit: (Data) throws -> Void) throws -> Bool {
        if finished { return true }
        var ended = false
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                stream.src_ptr = base
            } else {
                stream.src_ptr = UnsafePointer(out) // 빈 입력
            }
            stream.src_size = input.count
            while true {
                stream.dst_ptr = out
                stream.dst_size = Self.bufferSize
                let flags: Int32 = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(&stream, flags)
                let produced = Self.bufferSize - stream.dst_size
                if produced > 0 { try emit(Data(bytes: out, count: produced)) }

                if status == COMPRESSION_STATUS_END { ended = true; finished = true; return }
                if status == COMPRESSION_STATUS_ERROR { throw ConvertError.readFailed }
                if stream.dst_size == 0 { continue }                      // 출력 칸이 가득 참 → 더 나올 수 있음
                if stream.src_size == 0 && !finalize { return }           // 입력을 다 썼으니 다음 입력을 기다림
                if finalize && produced == 0 { throw ConvertError.readFailed } // 끝 표지 없이 잘린 데이터
            }
        }
        return ended
    }
}

// MARK: - 바이트 쓰기 도우미

private func put16(_ a: inout [UInt8], _ v: UInt16) {
    a.append(UInt8(v & 0xFF)); a.append(UInt8(v >> 8))
}
private func put32(_ a: inout [UInt8], _ v: UInt32) {
    a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
    a.append(UInt8((v >> 16) & 0xFF)); a.append(UInt8(v >> 24))
}
private func put64(_ a: inout [UInt8], _ v: UInt64) {
    put32(&a, UInt32(truncatingIfNeeded: v))
    put32(&a, UInt32(truncatingIfNeeded: v >> 32))
}

// MARK: - ZIP 쓰기 (4GB가 넘으면 ZIP64 사용)

final class ZipWriter {
    private struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let size: UInt64
        let offset: UInt64
        var needs64: Bool { size >= 0xFFFF_FFFF || compressedSize >= 0xFFFF_FFFF }
    }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [Entry] = []

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: url)
        else { throw ConvertError.writeFailed("") }
        handle = h
    }

    deinit { try? handle.close() }

    private func put(_ data: Data) throws {
        do { try handle.write(contentsOf: data) } catch { throw ConvertError.wrapping(error) }
        offset += UInt64(data.count)
    }

    private func localHeader(_ e: Entry) -> Data {
        let name = Array(e.name.utf8)
        var h: [UInt8] = []
        put32(&h, 0x0403_4B50)
        put16(&h, e.needs64 ? 45 : 20)       // 필요한 버전
        put16(&h, 0x0800)                    // 파일 이름이 UTF-8
        put16(&h, e.method)
        put16(&h, 0); put16(&h, 0x0021)      // 시간, 날짜(1980-01-01)
        put32(&h, e.crc)
        if e.needs64 {
            put32(&h, 0xFFFF_FFFF); put32(&h, 0xFFFF_FFFF)
            put16(&h, UInt16(name.count)); put16(&h, 20)
            h.append(contentsOf: name)
            put16(&h, 0x0001); put16(&h, 16)  // ZIP64 확장 필드: 원본 크기, 압축 크기
            put64(&h, e.size); put64(&h, e.compressedSize)
        } else {
            put32(&h, UInt32(e.compressedSize)); put32(&h, UInt32(e.size))
            put16(&h, UInt16(name.count)); put16(&h, 0)
            h.append(contentsOf: name)
        }
        return Data(h)
    }

    /// 작은 파일을 압축 없이 넣는다.
    func addStored(_ name: String, _ data: Data) throws {
        let entry = Entry(name: name, method: 0, crc: CRC32.update(0, data),
                          compressedSize: UInt64(data.count), size: UInt64(data.count), offset: offset)
        entries.append(entry)
        try put(localHeader(entry))
        try put(data)
    }

    /// 이미 만들어진 파일(압축된 본문 등)을 조금씩 복사해 넣는다.
    func addFile(_ name: String, from url: URL, method: UInt16, crc: UInt32, size: UInt64, compressedSize: UInt64) throws {
        let entry = Entry(name: name, method: method, crc: crc, compressedSize: compressedSize, size: size, offset: offset)
        entries.append(entry)
        try put(localHeader(entry))
        guard let input = try? FileHandle(forReadingFrom: url) else { throw ConvertError.readFailed }
        defer { try? input.close() }
        var copied: UInt64 = 0
        while true {
            try checkCancelled()
            let chunk: Data
            do { chunk = (try input.read(upToCount: 1 << 20)) ?? Data() } catch { throw ConvertError.readFailed }
            if chunk.isEmpty { break }
            try put(chunk)
            copied += UInt64(chunk.count)
        }
        guard copied == compressedSize else { throw ConvertError.writeFailed("") }
    }

    func finish() throws {
        let directoryStart = offset
        var directory: [UInt8] = []
        var anyZip64 = false
        for e in entries {
            let name = Array(e.name.utf8)
            let offset64 = e.offset >= 0xFFFF_FFFF
            let use64 = e.needs64 || offset64
            anyZip64 = anyZip64 || use64
            put32(&directory, 0x0201_4B50)
            put16(&directory, use64 ? 45 : 20); put16(&directory, use64 ? 45 : 20)
            put16(&directory, 0x0800); put16(&directory, e.method)
            put16(&directory, 0); put16(&directory, 0x0021)
            put32(&directory, e.crc)
            put32(&directory, e.needs64 ? 0xFFFF_FFFF : UInt32(e.compressedSize))
            put32(&directory, e.needs64 ? 0xFFFF_FFFF : UInt32(e.size))
            put16(&directory, UInt16(name.count))
            var extra: [UInt8] = []
            if e.needs64 { put64(&extra, e.size); put64(&extra, e.compressedSize) }
            if offset64 { put64(&extra, e.offset) }
            put16(&directory, extra.isEmpty ? 0 : UInt16(4 + extra.count))
            put16(&directory, 0)                 // 주석 길이
            put16(&directory, 0); put16(&directory, 0); put32(&directory, 0)
            put32(&directory, offset64 ? 0xFFFF_FFFF : UInt32(e.offset))
            directory.append(contentsOf: name)
            if !extra.isEmpty {
                put16(&directory, 0x0001); put16(&directory, UInt16(extra.count))
                directory.append(contentsOf: extra)
            }
        }
        try put(Data(directory))

        let directorySize = UInt64(directory.count)
        let need64End = anyZip64 || directoryStart >= 0xFFFF_FFFF || entries.count >= 0xFFFF
        var end: [UInt8] = []
        if need64End {
            let record64Start = offset
            put32(&end, 0x0606_4B50)
            put64(&end, 44)                       // 이 뒤로 이어지는 레코드 크기
            put16(&end, 45); put16(&end, 45)
            put32(&end, 0); put32(&end, 0)
            put64(&end, UInt64(entries.count)); put64(&end, UInt64(entries.count))
            put64(&end, directorySize); put64(&end, directoryStart)
            put32(&end, 0x0706_4B50)              // ZIP64 끝 위치 표지
            put32(&end, 0)
            put64(&end, record64Start)
            put32(&end, 1)
        }
        put32(&end, 0x0605_4B50)
        put16(&end, 0); put16(&end, 0)
        put16(&end, need64End ? 0xFFFF : UInt16(entries.count))
        put16(&end, need64End ? 0xFFFF : UInt16(entries.count))
        put32(&end, need64End ? 0xFFFF_FFFF : UInt32(directorySize))
        put32(&end, need64End ? 0xFFFF_FFFF : UInt32(directoryStart))
        put16(&end, 0)
        try put(Data(end))
        try? handle.close()
    }
}

// MARK: - ZIP 읽기 (ZIP64 지원, 항목을 파일로 풀면서 CRC 검증)

final class ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let size: UInt64
        let headerOffset: UInt64
        let encrypted: Bool
    }

    private let handle: FileHandle
    private(set) var entries: [String: Entry] = [:]

    init(url: URL) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ConvertError.readFailed }
        handle = h
        try readDirectory()
    }

    deinit { try? handle.close() }

    private func read(at position: UInt64, count: Int) throws -> Data {
        do {
            try handle.seek(toOffset: position)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw ConvertError.readFailed }
            return data
        } catch { throw ConvertError.readFailed }
    }

    private static func u16(_ d: Data, _ i: Int) -> UInt16 { UInt16(d[d.startIndex + i]) | (UInt16(d[d.startIndex + i + 1]) << 8) }
    private static func u32(_ d: Data, _ i: Int) -> UInt32 { UInt32(u16(d, i)) | (UInt32(u16(d, i + 2)) << 16) }
    private static func u64(_ d: Data, _ i: Int) -> UInt64 { UInt64(u32(d, i)) | (UInt64(u32(d, i + 4)) << 32) }

    private func readDirectory() throws {
        let fileSize: UInt64
        do { fileSize = try handle.seekToEnd() } catch { throw ConvertError.readFailed }
        guard fileSize >= 22 else { throw ConvertError.readFailed }

        // 끝에서 EOCD(끝 레코드) 찾기
        let tailLength = Int(min(fileSize, 22 + 65535))
        let tailStart = fileSize - UInt64(tailLength)
        let tail = try read(at: tailStart, count: tailLength)
        var eocd = -1
        var i = tailLength - 22
        while i >= 0 {
            if Self.u32(tail, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ConvertError.readFailed }

        var count = UInt64(Self.u16(tail, eocd + 10))
        var directorySize = UInt64(Self.u32(tail, eocd + 12))
        var directoryOffset = UInt64(Self.u32(tail, eocd + 16))

        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: 끝 레코드 바로 앞의 위치 표지를 따라간다
            guard eocd >= 20, Self.u32(tail, eocd - 20) == 0x0706_4B50 else { throw ConvertError.readFailed }
            let record64 = Self.u64(tail, eocd - 20 + 8)
            let r = try read(at: record64, count: 56)
            guard Self.u32(r, 0) == 0x0606_4B50 else { throw ConvertError.readFailed }
            count = Self.u64(r, 32)
            directorySize = Self.u64(r, 40)
            directoryOffset = Self.u64(r, 48)
        }
        guard directorySize <= 256 << 20, directoryOffset + directorySize <= fileSize else { throw ConvertError.readFailed }
        let directory = try read(at: directoryOffset, count: Int(directorySize))

        var pos = 0
        var parsed: UInt64 = 0
        while pos + 46 <= directory.count, parsed < count {
            guard Self.u32(directory, pos) == 0x0201_4B50 else { throw ConvertError.readFailed }
            let flags = Self.u16(directory, pos + 8)
            let method = Self.u16(directory, pos + 10)
            let crc = Self.u32(directory, pos + 16)
            var compressed = UInt64(Self.u32(directory, pos + 20))
            var size = UInt64(Self.u32(directory, pos + 24))
            let nameLength = Int(Self.u16(directory, pos + 28))
            let extraLength = Int(Self.u16(directory, pos + 30))
            let commentLength = Int(Self.u16(directory, pos + 32))
            var offset = UInt64(Self.u32(directory, pos + 42))
            guard pos + 46 + nameLength + extraLength + commentLength <= directory.count else { throw ConvertError.readFailed }

            let nameData = directory.subdata(in: (directory.startIndex + pos + 46)..<(directory.startIndex + pos + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""

            // ZIP64 확장 필드: 값이 0xFFFFFFFF인 항목만 순서대로 들어 있다
            var e = pos + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = Self.u16(directory, e)
                let length = Int(Self.u16(directory, e + 2))
                if id == 0x0001 {
                    var p = e + 4
                    let end = min(e + 4 + length, extraEnd)
                    if size == 0xFFFF_FFFF, p + 8 <= end { size = Self.u64(directory, p); p += 8 }
                    if compressed == 0xFFFF_FFFF, p + 8 <= end { compressed = Self.u64(directory, p); p += 8 }
                    if offset == 0xFFFF_FFFF, p + 8 <= end { offset = Self.u64(directory, p); p += 8 }
                }
                e += 4 + length
            }

            entries[name] = Entry(name: name, method: method, crc: crc, compressedSize: compressed,
                                  size: size, headerOffset: offset, encrypted: flags & 1 != 0)
            pos += 46 + nameLength + extraLength + commentLength
            parsed += 1
        }
    }

    /// 항목을 파일로 푼다. 풀면서 CRC32와 크기를 확인해 손상된 데이터는 오류로 처리한다.
    func extract(_ entry: Entry, to destination: URL, progress: ((Double) -> Void)? = nil) throws {
        guard !entry.encrypted, entry.method == 0 || entry.method == 8 else { throw ConvertError.unsupported("") }

        let local = try read(at: entry.headerOffset, count: 30)
        guard Self.u32(local, 0) == 0x0403_4B50 else { throw ConvertError.readFailed }
        let dataStart = entry.headerOffset + 30 + UInt64(Self.u16(local, 26)) + UInt64(Self.u16(local, 28))

        let writer = try BufferedWriter(url: destination)
        var codec: StreamCodec?
        if entry.method == 8 { codec = try StreamCodec(.decode) }
        var remaining = entry.compressedSize
        var position = dataStart
        do { try handle.seek(toOffset: position) } catch { throw ConvertError.readFailed }

        while remaining > 0 {
            try checkCancelled()
            let want = Int(min(remaining, 1 << 20))
            let chunk: Data
            do { chunk = (try handle.read(upToCount: want)) ?? Data() } catch { throw ConvertError.readFailed }
            guard !chunk.isEmpty else { throw ConvertError.readFailed } // 파일이 잘림
            remaining -= UInt64(chunk.count)
            position += UInt64(chunk.count)
            if let codec {
                try codec.process(chunk, finalize: remaining == 0) { try writer.write(data: $0) }
            } else {
                try writer.write(data: chunk)
            }
            progress?(entry.compressedSize == 0 ? 1 : Double(entry.compressedSize - remaining) / Double(entry.compressedSize))
        }
        if let codec, remaining == 0, entry.compressedSize == 0 {
            try codec.process(Data(), finalize: true) { try writer.write(data: $0) }
        }
        try writer.close()
        guard writer.byteCount == entry.size, writer.crc == entry.crc else { throw ConvertError.readFailed }
    }
}
