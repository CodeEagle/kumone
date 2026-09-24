import Foundation

// Sources/Kumone/Core/Providers/NetEaseMusicProvider.swift
//
// NetEase 源 provider 的主定义（Phase 1 / P1-a）。
//
// 只 conform `MusicAuth` + `MusicLogin` 两个登录域协议。其余能力域
// （Library / Playlist / Playback / Search / Discovery / Album / Artist 与
// 4 个 NetEase 特有域）由 P1-b~e 以独立 extension 文件补齐，最后再统一
// conform `NetEaseProvider`——在此之前写 `: NetEaseProvider` 会因缺少其余
// 10 个域的方法而编译失败。
//
// Access level: internal（与 MusicProvider.swift 一致；public 引用 internal
// 模型是 hard error，同 target 亦无需 public）。

/// NetEase 云音乐 provider。
///
/// 目前只实现登录域；能力域由后续 extension 补齐，最终聚合为 `NetEaseProvider`。
public struct NetEaseMusicProvider: MusicAuth, MusicLogin {

    /// 无状态 provider：所有方法都委托 `NeteaseClient`/`NeteaseAPI` 单例，
    /// 无 stored properties。默认 memberwise init 是 internal，这里显式公开，
    /// 供 executable 层在启动时注册到 `MusicProviderKey`（SF-0014 决策 8）。
    public init() {}

    // MARK: - MusicAuth

    public var isLoggedIn: Bool {
        NeteaseClient.shared.isLoggedIn
    }

    public func logout() async {
        await NeteaseAPI.logout()
    }

    public func refreshLogin() async {
        await NeteaseAPI.refreshLogin()
    }

    // MARK: - MusicLogin

    public var supportedMethods: [LoginMethod] {
        // `.qrCode` 是无参标记 case（v2 修订 T7）：二维码图片 URL 由 qrLoginURL(_:) 提供。
        [.qrCode]
    }

    /// 二维码图片地址（纯函数：无网络），由 `qrKey()` 取到的 unikey 拼成。
    public func qrLoginURL(_ unikey: String) -> URL {
        // NeteaseAPI 返回固定的 music.163.com 登录页 URL（域名+codekey 拼接），
        // 恒为合法地址，故强制解包：一旦服务端格式生变会立刻在调试期崩溃，
        // 而非静默降级到错误页面。
        URL(string: NeteaseAPI.qrLoginURL(unikey: unikey))!
    }

    public func qrKey() async throws -> String {
        try await NeteaseAPI.qrKey()
    }

    /// 轮询扫码状态：800 过期 · 801 等待 · 802 已扫描待确认 · 803 成功。
    public func qrCheck(_ unikey: String) async throws -> LoginCheck {
        let resp = try await NeteaseAPI.qrCheck(unikey: unikey)
        return LoginCheck(code: resp.code,
                          message: resp.message,
                          nickname: resp.nickname,
                          // QRCheckResponse.avatarUrl(String?) → LoginCheck.avatar(URL?)
                          avatar: resp.avatarUrl.flatMap(URL.init(string:)))
    }

    public func sendSMSCode(phone: String, countryCode: String) async throws {
        // NeteaseAPI 侧 countryCode 默认 "86"，此处透传调用方传入的区号。
        try await NeteaseAPI.sendSMSCode(phone: phone, countryCode: countryCode)
    }

    public func loginCellphone(phone: String, captcha: String, countryCode: String) async throws {
        try await NeteaseAPI.loginCellphone(phone: phone, captcha: captcha, countryCode: countryCode)
    }
}
