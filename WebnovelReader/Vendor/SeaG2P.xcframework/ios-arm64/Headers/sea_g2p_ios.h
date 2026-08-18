#ifndef SEA_G2P_IOS_H
#define SEA_G2P_IOS_H
#include <stdbool.h>

typedef struct SeaG2PContext SeaG2PContext;

SeaG2PContext *sea_g2p_open(const char *dict_path);
void sea_g2p_close(SeaG2PContext *ctx);
char *sea_g2p_phonemize(const SeaG2PContext *ctx, const char *text);
char *sea_g2p_normalize(const SeaG2PContext *ctx, const char *text, bool punc_norm);
char *sea_g2p_punc_norm(const char *text);
void sea_g2p_free_string(char *s);

#endif
