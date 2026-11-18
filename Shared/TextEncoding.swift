import Foundation

/// Korean Windows' encoding (EUC-KR and more): Excel's CSV and many public-data downloads.
let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

/// Byte-order marks and the encodings they announce: UTF-8 (Excel's "CSV UTF-8"), and UTF-16, which
/// Windows calls "Unicode" (desktop.ini, Notepad).
let byteOrderMarks: [(bom: Data, encoding: String.Encoding)] = [
    (Data([0xEF, 0xBB, 0xBF]), .utf8), (Data([0xFF, 0xFE]), .utf16LittleEndian), (Data([0xFE, 0xFF]), .utf16BigEndian),
]

/// A text file's text, with the encoding and byte-order mark that save it back byte for byte; nil for
/// anything that wouldn't, rather than decode lossily and overwrite the original on save.
func decodeText(_ data: Data) -> (text: String, encoding: String.Encoding, bom: Data)? {
    if !data.starts(with: [0xFF, 0xFE, 0, 0]), // UTF-32, which shares UTF-16's first bytes
       let mark = byteOrderMarks.first(where: { data.starts(with: $0.bom) }) {
        // An odd last byte of UTF-16, or a second UTF-8 mark, decodes but would be dropped on save.
        let body = data.dropFirst(mark.bom.count)
        guard let text = String(data: body, encoding: mark.encoding), text.data(using: mark.encoding) == body else { return nil }
        return (text, mark.encoding, mark.bom)
    }
    if let text = String(data: data, encoding: .utf8) { return (text, .utf8, Data()) }
    // Only CP949 that saves back byte for byte: its user-defined rows decode but don't encode.
    if let text = String(data: data, encoding: cp949), text.data(using: cp949) == data { return (text, cp949, Data()) }
    return nil
}
