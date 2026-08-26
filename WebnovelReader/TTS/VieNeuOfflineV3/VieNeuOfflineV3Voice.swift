import Foundation

/// The 14 built-in speaker presets bundled with the `vieneu` PyPI package
/// (`vieneu/assets/voices_v3_turbo.json`, the same file the server's
/// `vieneu.Vieneu(mode="v3turbo")` reads for its own preset voices) — each
/// is a 192-float x-vector speaker embedding + a short (~40-60 frame)
/// reference-code sequence (16 channels/frame), bundled individually as
/// `Resources/VieNeuOfflineV3/voice_<slug>.json`. Unlike V2's fixed
/// embedding-only presets, both fields feed the model every frame (see
/// VieNeuOfflineV3TTSService's doc comment) — selecting one changes the
/// full voice identity, not just a decode-time embedding swap.
enum VieNeuOfflineV3Voice: String, CaseIterable, Identifiable, Codable {
    case minhDuc = "voice_minh_duc"
    case phamTuyen = "voice_pham_tuyen"
    case thaiSon = "voice_thai_son"
    case xuanVinh = "voice_xuan_vinh"
    case thanhBinh = "voice_thanh_binh"
    case trucLy = "voice_truc_ly"
    case ngocLinh = "voice_ngoc_linh"
    case doanTrang = "voice_doan_trang"
    case maiAnh = "voice_mai_anh"
    case thucDoan = "voice_thuc_doan"
    case minhTriet = "voice_minh_triet"
    case thuyDung = "voice_thuy_dung"
    case quangSon = "voice_quang_son"
    case ngocTran = "voice_ngoc_tran"

    var id: String { rawValue }

    /// "{Tên} ({Giới tính} - Miền {Vùng} - {Phong cách})", matching
    /// voices_v3_turbo.json's `description` field for each preset.
    var displayName: String {
        switch self {
        case .minhDuc: return "Minh Đức (Male - Northern - News)"
        case .phamTuyen: return "Phạm Tuyên (Male - Northern - Natural)"
        case .thaiSon: return "Thái Sơn (Male - Southern - Storytelling)"
        case .xuanVinh: return "Xuân Vĩnh (Male - Southern - Natural)"
        case .thanhBinh: return "Thanh Bình (Male - Northern - Storytelling)"
        case .trucLy: return "Trúc Ly (Female - Northern - Natural)"
        case .ngocLinh: return "Ngọc Linh (Female - Northern - Storytelling)"
        case .doanTrang: return "Đoan Trang (Female - Northern - Natural)"
        case .maiAnh: return "Mai Anh (Female - Northern - News)"
        case .thucDoan: return "Thục Đoan (Female - Southern - Storytelling)"
        case .minhTriet: return "Minh Triết (Male - Southern - News)"
        case .thuyDung: return "Thùy Dung (Female - Southern - News)"
        case .quangSon: return "Quang Sơn (Male - Central - Natural)"
        case .ngocTran: return "Ngọc Trân (Female - Central - Natural)"
        }
    }
}
