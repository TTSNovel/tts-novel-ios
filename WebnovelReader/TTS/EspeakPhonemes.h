#ifndef EspeakPhonemes_h
#define EspeakPhonemes_h

// espeak-ng is linked statically inside sherpa-onnx (SherpaOnnxC), which
// doesn't ship its headers — just the two entry points
// PiperEnglishTransliterator needs, declared to match espeak-ng's
// speak_lib.h (espeak_ERROR is a plain C enum, i.e. int-sized).
int espeak_SetVoiceByName(const char *name);
const char *espeak_TextToPhonemes(const void **textptr, int textmode, int phonememode);

#endif
