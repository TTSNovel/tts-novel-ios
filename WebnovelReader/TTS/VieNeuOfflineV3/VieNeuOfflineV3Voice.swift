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
        case .minhDuc: return "Minh Đức (Nam - Miền Bắc - Tin tức)"
        case .phamTuyen: return "Phạm Tuyên (Nam - Miền Bắc - Tự nhiên)"
        case .thaiSon: return "Thái Sơn (Nam - Miền Nam - Kể chuyện)"
        case .xuanVinh: return "Xuân Vĩnh (Nam - Miền Nam - Tự nhiên)"
        case .thanhBinh: return "Thanh Bình (Nam - Miền Bắc - Kể chuyện)"
        case .trucLy: return "Trúc Ly (Nữ - Miền Bắc - Tự nhiên)"
        case .ngocLinh: return "Ngọc Linh (Nữ - Miền Bắc - Kể chuyện)"
        case .doanTrang: return "Đoan Trang (Nữ - Miền Bắc - Tự nhiên)"
        case .maiAnh: return "Mai Anh (Nữ - Miền Bắc - Tin tức)"
        case .thucDoan: return "Thục Đoan (Nữ - Miền Nam - Kể chuyện)"
        case .minhTriet: return "Minh Triết (Nam - Miền Nam - Tin tức)"
        case .thuyDung: return "Thùy Dung (Nữ - Miền Nam - Tin tức)"
        case .quangSon: return "Quang Sơn (Nam - Miền Trung - Tự nhiên)"
        case .ngocTran: return "Ngọc Trân (Nữ - Miền Trung - Tự nhiên)"
        }
    }
}
