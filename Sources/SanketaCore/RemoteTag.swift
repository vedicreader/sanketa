import Foundation

public struct RemoteTag: Hashable {
    public var host: String
    public var layers: [String]
    public init(host: String, layers: [String]) { self.host = host; self.layers = layers }

    static let re = try! NSRegularExpression(
        pattern: #"^⟦sanketa host=([A-Za-z0-9._-]{1,64}) layers=([A-Za-z0-9._+-]{1,32}(?:,[A-Za-z0-9._+-]{1,32}){0,7})⟧ ?"#)

    public static func parse(_ title: String) -> (tag: RemoteTag?, rest: String) {
        let ns = title as NSString
        guard let m = re.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) else { return (nil, title) }
        let tag = RemoteTag(host: ns.substring(with: m.range(at: 1)),
                            layers: ns.substring(with: m.range(at: 2)).components(separatedBy: ","))
        return (tag, ns.substring(from: m.range.upperBound))
    }
}
