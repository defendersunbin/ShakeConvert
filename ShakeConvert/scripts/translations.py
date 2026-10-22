#!/usr/bin/env python3
"""ShakeConvert 번역 원본.

키 = 앱 소스의 한국어 문장. 값 = [en, ja, zh-Hans, zh-Hant, es, fr, de]
macOS 공식 용어를 따른다 (예: 응용 프로그램 폴더 = Applications / 「アプリケーション」 / Programme).

생성: python3 scripts/translations.py Resources/Localization
검증: python3 scripts/check_l10n.py
"""
import os
import sys

LANGS = ["en", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de"]

T = {
    # ── 변환 패널 ─────────────────────────────────────────────
    "눌러서 취소": ["Click to cancel", "クリックで中止", "点按以取消", "按一下以取消", "Clic para cancelar", "Cliquez pour annuler", "Klicken zum Abbrechen"],
    "%@ 외 %ld개": [
        "%@ and %ld more", "%@ ほか%ld件", "%@ 等 %ld 个", "%@ 等 %ld 個",
        "%@ y %ld más", "%@ et %ld autres", "%@ und %ld weitere"],
    "%ld개 파일": [
        "%ld files", "%ld個のファイル", "%ld 个文件", "%ld 個檔案",
        "%ld archivos", "%ld fichiers", "%ld Dateien"],
    "놓으면 %@(으)로 변환": [
        "Drop to convert to %@", "ドロップして %@ に変換", "松开以转换为 %@", "放開以轉換為 %@",
        "Suelta para convertir a %@", "Déposez pour convertir en %@", "Loslassen zum Konvertieren in %@"],
    "놓으면 전체 형식 검색": [
        "Drop to search all formats", "ドロップしてすべての形式を検索", "松开以搜索所有格式", "放開以搜尋所有格式",
        "Suelta para buscar todos los formatos", "Déposez pour chercher tous les formats", "Loslassen, um alle Formate zu durchsuchen"],
    "놓으면 닫기": [
        "Drop to close", "ドロップして閉じる", "松开以关闭", "放開以關閉",
        "Suelta para cerrar", "Déposez pour fermer", "Loslassen zum Schließen"],
    "변환할 형식 검색": [
        "Search formats", "変換形式を検索", "搜索格式", "搜尋格式",
        "Buscar formato", "Rechercher un format", "Format suchen"],
    "일치하는 형식이 없습니다": [
        "No matching formats", "一致する形式がありません", "没有匹配的格式", "沒有符合的格式",
        "No hay formatos coincidentes", "Aucun format correspondant", "Keine passenden Formate"],
    "‹ 링으로": [
        "‹ Back to ring", "‹ リングに戻る", "‹ 返回圆环", "‹ 返回圓環",
        "‹ Volver al anillo", "‹ Retour à l’anneau", "‹ Zurück zum Ring"],
    "더 보기": ["More", "その他", "更多", "更多", "Más", "Plus", "Mehr"],
    "검색": ["Search", "検索", "搜索", "搜尋", "Buscar", "Rechercher", "Suchen"],
    "다시": ["Retry", "やり直す", "重试", "重試", "Reintentar", "Réessayer", "Erneut"],
    "닫기": ["Close", "閉じる", "关闭", "關閉", "Cerrar", "Fermer", "Schließen"],
    "Finder에서 보기": [
        "Show in Finder", "Finderに表示", "在访达中显示", "在 Finder 中顯示",
        "Mostrar en el Finder", "Afficher dans le Finder", "Im Finder zeigen"],

    # ── 형식 / 분류 ───────────────────────────────────────────
    "이미지": ["Image", "画像", "图像", "影像", "Imagen", "Image", "Bild"],
    "문서/텍스트": ["Document/Text", "書類/テキスト", "文稿/文本", "文件/文字", "Documento/Texto", "Document/Texte", "Dokument/Text"],
    "오디오": ["Audio", "オーディオ", "音频", "音訊", "Audio", "Audio", "Audio"],
    "비디오": ["Video", "ビデオ", "视频", "影片", "Vídeo", "Vidéo", "Video"],
    "텍스트": ["Text", "テキスト", "文本", "文字", "Texto", "Texte", "Text"],
    "페이지별": ["Per page", "ページごと", "按页", "逐頁", "Por página", "Par page", "Pro Seite"],
    "래스터 임베드": ["Embedded raster", "ラスター埋め込み", "嵌入位图", "內嵌點陣圖", "Ráster incrustado", "Matriciel intégré", "Eingebettetes Raster"],
    "오디오만": ["Audio only", "オーディオのみ", "仅音频", "僅音訊", "Solo audio", "Audio seul", "Nur Audio"],
    # 검색용 별칭 (화면에 직접 표시되지 않음)
    "벡터": ["vector", "ベクター", "矢量", "向量", "vectorial", "vectoriel", "Vektor"],
    "리치": ["rich", "リッチ", "富文本", "豐富", "enriquecido", "enrichi", "formatiert"],
    "워드": ["word", "ワード", "文字处理", "文書處理", "procesador", "traitement", "Textverarbeitung"],
    "웹": ["web", "ウェブ", "网页", "網頁", "web", "web", "Web"],
    "소리": ["sound", "サウンド", "声音", "聲音", "sonido", "son", "Ton"],
    "음원": ["music", "音源", "音乐", "音樂", "música", "musique", "Musik"],
    "추출": ["extract", "抽出", "提取", "擷取", "extraer", "extraire", "extrahieren"],
    "[이미지: %@]": ["[Image: %@]", "[画像: %@]", "[图像：%@]", "[影像：%@]", "[Imagen: %@]", "[Image : %@]", "[Bild: %@]"],
    "페이지 %ld / %ld": ["Page %ld / %ld", "ページ %ld / %ld", "第 %ld / %ld 页", "第 %ld / %ld 頁", "Página %ld / %ld", "Page %ld / %ld", "Seite %ld / %ld"],

    # ── 오류 ──────────────────────────────────────────────────
    "%@: 이 형식으로는 변환할 수 없습니다": [
        "%@: Can’t convert to this format", "%@: この形式には変換できません", "%@：无法转换为此格式", "%@：無法轉換為此格式",
        "%@: No se puede convertir a este formato", "%@ : impossible de convertir dans ce format", "%@: In dieses Format kann nicht konvertiert werden"],
    "일반 파일만 변환할 수 있습니다 (심볼릭 링크/폴더 제외)": [
        "Only regular files can be converted (no symbolic links or folders)", "通常のファイルのみ変換できます（シンボリックリンク/フォルダを除く）",
        "只能转换普通文件（不包括符号链接/文件夹）", "只能轉換一般檔案（不含符號連結/檔案夾）",
        "Solo se pueden convertir archivos normales (sin enlaces simbólicos ni carpetas)", "Seuls les fichiers ordinaires peuvent être convertis (pas de liens symboliques ni de dossiers)",
        "Nur normale Dateien können konvertiert werden (keine symbolischen Links oder Ordner)"],
    "파일이 너무 큽니다": ["The file is too large", "ファイルが大きすぎます", "文件太大", "檔案太大", "El archivo es demasiado grande", "Le fichier est trop volumineux", "Die Datei ist zu groß"],
    "이미지 해상도가 너무 큽니다": ["The image resolution is too high", "画像の解像度が高すぎます", "图像分辨率过高", "影像解析度過高", "La resolución de la imagen es demasiado alta", "La résolution de l’image est trop élevée", "Die Bildauflösung ist zu hoch"],
    "페이지 수가 너무 많습니다": ["Too many pages", "ページ数が多すぎます", "页数过多", "頁數過多", "Demasiadas páginas", "Trop de pages", "Zu viele Seiten"],
    "지원하지 않는 변환입니다": ["This conversion isn’t supported", "この変換には対応していません", "不支持此转换", "不支援此轉換", "Esta conversión no es compatible", "Cette conversion n’est pas prise en charge", "Diese Konvertierung wird nicht unterstützt"],
    "파일을 읽을 수 없습니다": ["The file can’t be read", "ファイルを読み込めません", "无法读取文件", "無法讀取檔案", "No se puede leer el archivo", "Impossible de lire le fichier", "Die Datei kann nicht gelesen werden"],
    "암호로 보호된 파일입니다": ["The file is password-protected", "パスワードで保護されたファイルです", "文件受密码保护", "檔案受密碼保護", "El archivo está protegido con contraseña", "Le fichier est protégé par un mot de passe", "Die Datei ist passwortgeschützt"],
    "결과 파일을 저장하지 못했습니다": ["Couldn’t save the converted file", "変換したファイルを保存できませんでした", "无法存储转换后的文件", "無法儲存轉換後的檔案", "No se pudo guardar el archivo convertido", "Impossible d’enregistrer le fichier converti", "Die konvertierte Datei konnte nicht gesichert werden"],
    "저장 실패: %@": ["Save failed: %@", "保存に失敗しました: %@", "存储失败：%@", "儲存失敗：%@", "Error al guardar: %@", "Échec de l’enregistrement : %@", "Sichern fehlgeschlagen: %@"],
    "이 Mac에서는 해당 형식으로 저장할 수 없습니다": ["This Mac can’t save in that format", "このMacではその形式で保存できません", "这台 Mac 无法以该格式存储", "這台 Mac 無法以該格式儲存", "Este Mac no puede guardar en ese formato", "Ce Mac ne peut pas enregistrer dans ce format", "Dieser Mac kann nicht in diesem Format sichern"],
    "이 파일은 해당 형식으로 내보낼 수 없습니다": ["This file can’t be exported to that format", "このファイルはその形式で書き出せません", "此文件无法导出为该格式", "此檔案無法輸出為該格式", "Este archivo no se puede exportar a ese formato", "Ce fichier ne peut pas être exporté dans ce format", "Diese Datei kann nicht in dieses Format exportiert werden"],
    "오디오 트랙이 없습니다": ["There’s no audio track", "オーディオトラックがありません", "没有音轨", "沒有音軌", "No hay pista de audio", "Aucune piste audio", "Keine Audiospur vorhanden"],
    "3채널 이상 오디오는 아직 지원하지 않습니다": ["Audio with more than 2 channels isn’t supported yet", "3チャンネル以上のオーディオにはまだ対応していません", "暂不支持 3 声道及以上的音频", "尚不支援 3 聲道以上的音訊", "El audio de más de 2 canales aún no es compatible", "L’audio de plus de 2 canaux n’est pas encore pris en charge", "Audio mit mehr als 2 Kanälen wird noch nicht unterstützt"],

    # ── 메뉴바 / 실행 알림 ───────────────────────────────────
    "파일을 잡고 좌우로 흔들면 변환 메뉴가 나타납니다": [
        "Grab a file and shake it left and right to open the conversion menu", "ファイルをつかんで左右に振ると変換メニューが表示されます",
        "抓住文件左右摇动即可打开转换菜单", "抓住檔案左右搖動即可開啟轉換選單",
        "Agarra un archivo y agítalo a izquierda y derecha para abrir el menú de conversión", "Saisissez un fichier et secouez-le de gauche à droite pour ouvrir le menu de conversion",
        "Datei greifen und nach links und rechts schütteln, um das Konvertierungsmenü zu öffnen"],
    "실행 상태 보기": ["Show Status", "ステータスを表示", "显示状态", "顯示狀態", "Mostrar estado", "Afficher l’état", "Status anzeigen"],
    "설정…": ["Settings…", "設定…", "设置…", "設定…", "Ajustes…", "Réglages…", "Einstellungen …"],
    "종료": ["Quit", "終了", "退出", "結束", "Salir", "Quitter", "Beenden"],
    "실행 중": ["Running", "実行中", "运行中", "執行中", "En ejecución", "En cours", "Aktiv"],
    "파일을 잡고 좌우로 흔들어 보세요": ["Grab a file and shake it left and right", "ファイルをつかんで左右に振ってみてください", "抓住文件左右摇一摇", "抓住檔案左右搖一搖", "Agarra un archivo y agítalo", "Saisissez un fichier et secouez-le", "Datei greifen und schütteln"],

    # ── 설정 창 ──────────────────────────────────────────────
    "ShakeConvert 설정": ["ShakeConvert Settings", "ShakeConvert 設定", "ShakeConvert 设置", "ShakeConvert 設定", "Ajustes de ShakeConvert", "Réglages de ShakeConvert", "ShakeConvert-Einstellungen"],
    "버전 %@": ["Version %@", "バージョン %@", "版本 %@", "版本 %@", "Versión %@", "Version %@", "Version %@"],
    "모든 변환은 이 Mac 안에서만": ["All conversions stay on this Mac", "すべての変換はこのMac内で完結", "所有转换仅在这台 Mac 上进行", "所有轉換僅在這台 Mac 上進行", "Todo se convierte en este Mac", "Tout est converti sur ce Mac", "Alles bleibt auf diesem Mac"],
    "일반": ["General", "一般", "通用", "一般", "General", "Général", "Allgemein"],
    "로그인 시 자동 실행": ["Open at login", "ログイン時に開く", "登录时打开", "登入時打開", "Abrir al iniciar sesión", "Ouvrir à la connexion", "Beim Anmelden öffnen"],
    "응용 프로그램(Applications) 폴더에 설치한 뒤 켜는 것을 권장합니다.": [
        "We recommend turning this on after installing in the Applications folder.", "「アプリケーション」フォルダにインストールしてからオンにすることをおすすめします。",
        "建议先安装到“应用程序”文件夹再开启。", "建議先安裝到「應用程式」檔案夾再開啟。",
        "Se recomienda activarlo tras instalar en la carpeta Aplicaciones.", "Il est recommandé de l’activer après l’installation dans le dossier Applications.",
        "Empfohlen: Erst im Ordner „Programme“ installieren, dann aktivieren."],
    "시스템 설정 › 일반 › 로그인 항목에서 허용해 주세요.": [
        "Allow it in System Settings › General › Login Items.", "「システム設定」›「一般」›「ログイン項目」で許可してください。",
        "请在“系统设置”›“通用”›“登录项”中允许。", "請在「系統設定」›「一般」›「登入項目」中允許。",
        "Permítelo en Ajustes del Sistema › General › Ítems de inicio.", "Autorisez-le dans Réglages Système › Général › Ouverture.",
        "Erlaube es unter Systemeinstellungen › Allgemein › Anmeldeobjekte."],
    "로그인 항목 열기": ["Open Login Items", "ログイン項目を開く", "打开登录项", "打開登入項目", "Abrir ítems de inicio", "Ouvrir Ouverture", "Anmeldeobjekte öffnen"],
    "설정하지 못했습니다: %@": ["Couldn’t change the setting: %@", "設定できませんでした: %@", "无法更改设置：%@", "無法更改設定：%@", "No se pudo cambiar el ajuste: %@", "Impossible de modifier le réglage : %@", "Einstellung konnte nicht geändert werden: %@"],
    "실행할 때 알림 표시": ["Show notice at launch", "起動時に通知を表示", "启动时显示提示", "啟動時顯示提示", "Mostrar aviso al abrir", "Afficher un avis au lancement", "Hinweis beim Start anzeigen"],
    "외관": ["Appearance", "外観", "外观", "外觀", "Apariencia", "Apparence", "Erscheinungsbild"],
    "테마": ["Theme", "テーマ", "主题", "主題", "Tema", "Thème", "Design"],
    "시스템": ["System", "システム", "系统", "系統", "Sistema", "Système", "System"],
    "라이트": ["Light", "ライト", "浅色", "淺色", "Claro", "Clair", "Hell"],
    "다크": ["Dark", "ダーク", "深色", "深色", "Oscuro", "Sombre", "Dunkel"],
    "언어": ["Language", "言語", "语言", "語言", "Idioma", "Langue", "Sprache"],
    "표시 언어": ["Display language", "表示言語", "显示语言", "顯示語言", "Idioma de la interfaz", "Langue d’affichage", "Anzeigesprache"],
    "시스템 언어 따르기": ["Same as system", "システムと同じ", "跟随系统", "跟隨系統", "Igual que el sistema", "Comme le système", "Wie System"],
    "다시 시작하면 적용됩니다.": ["Takes effect after restarting.", "再起動後に反映されます。", "重新启动后生效。", "重新啟動後生效。", "Se aplicará al reiniciar.", "Prendra effet après le redémarrage.", "Wird nach dem Neustart wirksam."],
    "지금 다시 시작": ["Restart Now", "今すぐ再起動", "立即重新启动", "立即重新啟動", "Reiniciar ahora", "Redémarrer maintenant", "Jetzt neu starten"],
    "흔들기 · 저장": ["Shake · Save", "シェイク · 保存", "摇动 · 存储", "搖動 · 儲存", "Agitar · Guardar", "Secouer · Enregistrer", "Schütteln · Sichern"],
    "흔들기 감도": ["Shake sensitivity", "シェイクの感度", "摇动灵敏度", "搖動靈敏度", "Sensibilidad al agitar", "Sensibilité de secousse", "Schüttel-Empfindlichkeit"],
    "둔감": ["Low", "低", "低", "低", "Baja", "Faible", "Niedrig"],
    "보통": ["Normal", "標準", "中", "中", "Normal", "Normale", "Normal"],
    "민감": ["High", "高", "高", "高", "Alta", "Élevée", "Hoch"],
    "저장 위치": ["Save to", "保存先", "存储位置", "儲存位置", "Guardar en", "Enregistrer dans", "Sichern in"],
    "원본 파일 옆": ["Next to original", "元のファイルと同じ場所", "原文件旁边", "原始檔案旁邊", "Junto al original", "À côté de l’original", "Neben dem Original"],
    "다운로드 폴더": ["Downloads folder", "「ダウンロード」フォルダ", "“下载”文件夹", "「下載項目」檔案夾", "Carpeta Descargas", "Dossier Téléchargements", "Ordner „Downloads“"],
    "변환 완료 후 자동으로 닫기": ["Close after converting", "変換後に自動で閉じる", "转换后自动关闭", "轉換後自動關閉", "Cerrar tras convertir", "Fermer après la conversion", "Nach Konvertierung schließen"],
    "%ld초": ["%ld sec", "%ld秒", "%ld 秒", "%ld 秒", "%ld s", "%ld s", "%ld Sek."],
    "1분": ["1 min", "1分", "1 分钟", "1 分鐘", "1 min", "1 min", "1 Min."],
    "닫지 않음": ["Don’t close", "閉じない", "不自动关闭", "不自動關閉", "No cerrar", "Ne pas fermer", "Nicht schließen"],
    "변환 후 Finder에서 결과 보기": ["Show result in Finder after converting", "変換後にFinderで結果を表示", "转换后在访达中显示结果", "轉換後在 Finder 中顯示結果", "Mostrar el resultado en el Finder", "Afficher le résultat dans le Finder", "Ergebnis danach im Finder zeigen"],
    "변환 품질": ["Conversion quality", "変換品質", "转换质量", "轉換品質", "Calidad de conversión", "Qualité de conversion", "Konvertierungsqualität"],
    "JPEG · HEIC 품질": ["JPEG · HEIC quality", "JPEG · HEIC の画質", "JPEG · HEIC 质量", "JPEG · HEIC 品質", "Calidad JPEG · HEIC", "Qualité JPEG · HEIC", "JPEG · HEIC-Qualität"],
    "문서 → PDF 용지": ["Document → PDF paper", "書類 → PDF 用紙", "文稿 → PDF 纸张", "文件 → PDF 紙張", "Papel de documento → PDF", "Papier document → PDF", "Papier für Dokument → PDF"],

    # ── 설치 도우미 ──────────────────────────────────────────
    "ShakeConvert를 응용 프로그램 폴더로 옮길까요?": [
        "Move ShakeConvert to the Applications folder?", "ShakeConvertを「アプリケーション」フォルダに移動しますか?",
        "要将 ShakeConvert 移到“应用程序”文件夹吗？", "要將 ShakeConvert 移到「應用程式」檔案夾嗎？",
        "¿Mover ShakeConvert a la carpeta Aplicaciones?", "Déplacer ShakeConvert dans le dossier Applications ?",
        "ShakeConvert in den Ordner „Programme“ bewegen?"],
    "응용 프로그램 폴더에서 실행해야 로그인 시 자동 실행 등 모든 기능이 정상적으로 동작합니다.": [
        "Running from the Applications folder lets every feature, such as opening at login, work properly.",
        "「アプリケーション」フォルダから実行すると、ログイン時に開くなどすべての機能が正しく動作します。",
        "从“应用程序”文件夹运行，登录时打开等所有功能才能正常工作。", "從「應用程式」檔案夾執行，登入時打開等所有功能才能正常運作。",
        "Al ejecutarlo desde la carpeta Aplicaciones, todas las funciones, como abrir al iniciar sesión, funcionan correctamente.",
        "Lancé depuis le dossier Applications, toutes les fonctionnalités, comme l’ouverture à la connexion, fonctionnent correctement.",
        "Aus dem Ordner „Programme“ gestartet funktionieren alle Funktionen, z. B. das Öffnen beim Anmelden."],
    "이미 설치된 버전은 휴지통으로 이동합니다.": [
        "The version already installed will be moved to the Trash.", "インストール済みのバージョンはゴミ箱に移動されます。",
        "已安装的版本将被移到废纸篓。", "已安裝的版本將被移到垃圾桶。",
        "La versión ya instalada se moverá a la Papelera.", "La version déjà installée sera placée dans la Corbeille.",
        "Die bereits installierte Version wird in den Papierkorb gelegt."],
    "응용 프로그램 폴더로 이동": ["Move to Applications Folder", "「アプリケーション」フォルダに移動", "移到“应用程序”文件夹", "移到「應用程式」檔案夾", "Mover a Aplicaciones", "Déplacer dans Applications", "In „Programme“ bewegen"],
    "나중에": ["Not Now", "後で", "以后", "稍後", "Ahora no", "Plus tard", "Später"],
    "다시 묻지 않기": ["Don’t ask again", "今後確認しない", "不再询问", "不再詢問", "No volver a preguntar", "Ne plus demander", "Nicht mehr fragen"],
    "옮기지 못했습니다": ["Couldn’t move the app", "移動できませんでした", "无法移动", "無法移動", "No se pudo mover", "Impossible de déplacer l’app", "Bewegen nicht möglich"],
    "Finder에서 ShakeConvert를 응용 프로그램 폴더로 직접 끌어다 놓아 주세요.": [
        "Drag ShakeConvert to the Applications folder in the Finder.", "FinderでShakeConvertを「アプリケーション」フォルダにドラッグしてください。",
        "请在访达中将 ShakeConvert 拖到“应用程序”文件夹。", "請在 Finder 中將 ShakeConvert 拖移到「應用程式」檔案夾。",
        "Arrastra ShakeConvert a la carpeta Aplicaciones en el Finder.", "Faites glisser ShakeConvert dans le dossier Applications depuis le Finder.",
        "Ziehe ShakeConvert im Finder in den Ordner „Programme“."],
    "응용 프로그램 폴더에 같은 이름의 다른 앱이 있어 옮기지 않았습니다.": [
        "Another app with the same name is already in the Applications folder, so nothing was moved.",
        "「アプリケーション」フォルダに同じ名前の別のアプリがあるため、移動しませんでした。",
        "“应用程序”文件夹中已有同名的其他 App，因此未移动。", "「應用程式」檔案夾中已有同名的其他 App，因此未移動。",
        "Ya hay otra app con el mismo nombre en la carpeta Aplicaciones, así que no se movió nada.",
        "Une autre app portant le même nom se trouve déjà dans le dossier Applications ; rien n’a été déplacé.",
        "Im Ordner „Programme“ befindet sich bereits eine andere App mit diesem Namen. Es wurde nichts bewegt."],
    "복사본의 서명을 확인할 수 없어 설치를 취소했습니다.": [
        "The copy’s signature couldn’t be verified, so installation was canceled.", "コピーの署名を確認できなかったため、インストールを中止しました。",
        "无法验证副本的签名，已取消安装。", "無法驗證副本的簽名，已取消安裝。",
        "No se pudo verificar la firma de la copia, así que se canceló la instalación.", "La signature de la copie n’a pas pu être vérifiée ; l’installation a été annulée.",
        "Die Signatur der Kopie konnte nicht überprüft werden. Die Installation wurde abgebrochen."],
    "확인": ["OK", "OK", "好", "好", "Aceptar", "OK", "OK"],
}


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write(path, pairs):
    with open(path, "w", encoding="utf-8") as f:
        f.write("/* ShakeConvert — generated by scripts/translations.py. Edit that file, not this one. */\n\n")
        for k, v in pairs:
            f.write(f'"{escape(k)}" = "{escape(v)}";\n')


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Resources/Localization"
    for key, values in T.items():
        assert len(values) == len(LANGS), f"번역 개수 불일치: {key}"
    for i, lang in enumerate(LANGS):
        d = os.path.join(out, f"{lang}.lproj")
        os.makedirs(d, exist_ok=True)
        write(os.path.join(d, "Localizable.strings"), [(k, v[i]) for k, v in T.items()])
    d = os.path.join(out, "ko.lproj")
    os.makedirs(d, exist_ok=True)
    write(os.path.join(d, "Localizable.strings"), [(k, k) for k in T])  # 원문 = 한국어
    print(f"{len(T)} keys × {len(LANGS) + 1} languages → {out}")


if __name__ == "__main__":
    main()
