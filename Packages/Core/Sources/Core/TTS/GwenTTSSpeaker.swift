import Foundation

/// The 9 built-in reference speakers baked into the tts-gpu Cloud Run image
/// (tts-pipeline-infra's src/tts-gpu/gwen_data/ref_info.json) — each is a
/// short reference clip + transcript the server conditions the voice clone
/// on, not something synthesized on-device (unlike VieNeuOfflineV2Voice).
/// Selecting one just adds a `speaker` field to the /api/tts request body;
/// rawValues must match ref_info.json's keys exactly.
public enum GwenTTSSpeaker: String, CaseIterable, Identifiable, Codable, Sendable {
    case yenNhi = "yen_nhi"
    case myVan = "my_van"
    case aiVy = "ai_vy"
    case anNhi = "an_nhi"
    case dieuLinh = "dieu_linh"
    case khanhToan = "khanh_toan"
    case tranLam = "tran_lam"
    case nsndHaPhuong = "nsnd_ha_phuong"
    case nsndKimCuc = "nsnd_kim_cuc"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .yenNhi: return "Yến Nhi"
        case .myVan: return "Mỹ Vân"
        case .aiVy: return "Ái Vy"
        case .anNhi: return "An Nhi"
        case .dieuLinh: return "Diệu Linh"
        case .khanhToan: return "Khánh Toàn"
        case .tranLam: return "Trần Lâm"
        case .nsndHaPhuong: return "NSND Hà Phương"
        case .nsndKimCuc: return "NSND Kim Cúc"
        }
    }
}
