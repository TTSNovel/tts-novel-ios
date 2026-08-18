import Foundation

/// The 4 speaker presets published alongside `pnnbao-ump/VieNeu-TTS-v2-
/// Turbo-GGUF` (its `voices.json`) — each is just a 128-float voice-
/// embedding vector (no reference audio/cloning involved, see
/// VieNeuCodecDecoder), bundled individually as `Resources/VieNeuOffline/
/// voice_<slug>.json`. Selecting one only changes which embedding feeds the
/// codec decode step; the backbone/G2P pipeline is identical either way.
enum VieNeuOfflineVoice: String, CaseIterable, Identifiable, Codable {
    case bichNgoc = "voice_bich_ngoc"
    case phamTuyen = "voice_pham_tuyen"
    case thucDoan = "voice_thuc_doan"
    case xuanVinh = "voice_xuan_vinh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bichNgoc: return "Bích Ngọc (Nữ - Miền Bắc)"
        case .phamTuyen: return "Phạm Tuyên (Nam - Miền Bắc)"
        case .thucDoan: return "Thục Đoan (Nữ - Miền Nam)"
        case .xuanVinh: return "Xuân Vĩnh (Nam - Miền Nam)"
        }
    }
}
