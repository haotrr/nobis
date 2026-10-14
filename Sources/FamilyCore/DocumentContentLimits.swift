import Foundation
import FamilyDomain

/// Keep prose limits while allowing a bounded, self-contained set of JPEG photos.
public enum DocumentContentLimits {
    public static let maximumFileBytes = 800 * 1024
    public static let maximumImageBytes = 512 * 1024
    public static func validate(_ source: String) throws {
        guard source.utf8.count <= maximumFileBytes else { throw NobisError.validation("这篇笔记的图片内容较多，请拆分到另一篇笔记。") }
        let pattern = #"!\[(?:\\.|[^\]])*\]\(<?(data:image/jpeg;base64,[A-Za-z0-9+/=]+)>?(?: +\"[^\"]*\")?\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var prose = source, total = 0
        for match in matches.reversed() {
            let address = ns.substring(with: match.range(at: 1))
            guard let data = Data(base64Encoded: String(address.dropFirst("data:image/jpeg;base64,".count))),
                  data.starts(with: [0xff, 0xd8, 0xff]) else { throw NobisError.validation("笔记中的照片数据无效。") }
            total += data.count
            guard total <= maximumImageBytes else { throw NobisError.validation("这篇笔记的图片内容较多，请拆分到另一篇笔记。") }
            if let range = Range(match.range(at: 1), in: prose) { prose.replaceSubrange(range, with: "照片") }
        }
        guard prose.count <= 20_000 else { throw NobisError.validation("笔记正文不能超过 20,000 字。") }
    }
}
