// macOS bridging header — only the espeak-ng entry points Piper's English
// transliteration needs (sherpa-onnx links espeak-ng statically). The iOS
// header (VieNeu-Bridging-Header.h) also pulls in SeaG2P/VieNeu/OPUS-MT,
// which have no macOS build yet.
#ifndef Piper_Bridging_Header_h
#define Piper_Bridging_Header_h

#import "../WebnovelReader/TTS/EspeakPhonemes.h"

#endif
