/* O aperto de mão TLS do Chrome no OpenSSL do curl (CURLOPT_SSL_CTX_FUNCTION, ver
 * platform/sys.zig `curlTls`). O app se apresenta como o Chrome em todo pedido
 * (net/web_client.zig); com o TLS padrão do OpenSSL, a impressão da conexão (JA4)
 * dizia outra coisa, e um token de navegador usado por algo que não é navegador é
 * justamente o que o Discord procura.
 *
 * Os valores são os do Chromium 156 medidos em tls.peet.ws (tools/tls_check.sh compara
 * os dois): as mesmas 15 cifras e 16 extensões, os mesmos grupos e assinaturas. O JA4
 * ignora a ordem das extensões (o Chrome sorteia) e os valores GREASE. Os GREASE das
 * cifras, dos grupos e das versões o OpenSSL não manda; os das extensões, sim.
 *
 * Roda depois de o curl montar o SSL_CTX (um por conexão), então manda sobre o que o
 * curl pôs. O que este OpenSSL não souber fazer fica de fora sem derrubar a conexão. */
#include <openssl/ssl.h>
#include <openssl/bio.h>
#include <openssl/rand.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <time.h>
#endif

int larper_tls_chrome(void *ssl_ctx, int h1_only);
void larper_dpi_set_mode(int mode);
int larper_dpi_get_mode(void);

static const char ciphers12[] =
    "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:"
    "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:"
    "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:"
    "ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:"
    "AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA";
static const char ciphers13[] = "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256";
/* Os dois primeiros levam chave pronta no ClientHello (o "*"), como no Chrome. */
static const char groups[] = "*X25519MLKEM768:*X25519:P-256:P-384";
static const char groups_old[] = "X25519:P-256:P-384";
#define SIGALGS_CLASSIC                                                                     \
    "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256:rsa_pkcs1_sha256:"                          \
    "ecdsa_secp384r1_sha384:rsa_pss_rsae_sha384:rsa_pkcs1_sha384:"                          \
    "rsa_pss_rsae_sha512:rsa_pkcs1_sha512"
static const char sigalgs[] = "mldsa44:mldsa65:mldsa87:" SIGALGS_CLASSIC;
static const char sigalgs_old[] = SIGALGS_CLASSIC;

/* Extensões que o OpenSSL não conhece: ALPS e o ECH de mentira (GREASE). */
#define EXT_ALPS 17613
#define EXT_ECH 0xfe0d
/* ALPS: os protocolos com configurações (só o h2), como o Chrome manda. Só para os
 * servidores do Discord, onde a impressão importa: um servidor que aceita o ALPS (os do
 * Google aceitam) espera uma mensagem a mais no fim do aperto de mão que o OpenSSL não
 * sabe mandar, e a conexão cai. Se um dia um do Discord aceitar, a conexão que viu isso
 * cai e as próximas saem sem ALPS. */
static const unsigned char alps_body[] = {0x00, 0x03, 0x02, 'h', '2'};
static volatile int alps_off, alps_everywhere;
static const char *const discord_hosts[] = {"discord.com", "discordapp.com", "discordapp.net", "discord.gg", "discord.media"};

static int ends_with_host(const char *h, const char *base) {
    size_t n = strlen(h), m = strlen(base);
    if (n < m || strcmp(h + n - m, base) != 0) return 0;
    return n == m || h[n - m - 1] == '.';
}

static int discord_host(SSL *s) {
    if (alps_everywhere) return 1;
    const char *h = SSL_get_servername(s, TLSEXT_NAMETYPE_host_name);
    if (!h) return 0;
    for (size_t i = 0; i < sizeof discord_hosts / sizeof discord_hosts[0]; i++)
        if (ends_with_host(h, discord_hosts[i])) return 1;
    return 0;
}

/* Um dos 16 valores GREASE (0x0a0a, 0x1a1a … 0xfafa), diferente de `other`. */
static unsigned grease(unsigned other) {
    for (;;) {
        unsigned char r = 0;
        if (RAND_bytes(&r, 1) != 1) r = 0x2a;
        unsigned v = ((r & 0xf0u) | 0x0au) * 0x101u;
        if (v != other) return v;
    }
}

static int add_fixed(SSL *s, unsigned int type, unsigned int ctx, const unsigned char **out, size_t *outlen, X509 *x,
                     size_t chain, int *al, void *arg) {
    (void)ctx, (void)x, (void)chain, (void)al;
    if (type == EXT_ALPS) {
        if (alps_off || !discord_host(s)) return 0;
        *out = alps_body;
        *outlen = sizeof alps_body;
    } else {
        /* GREASE: o primeiro vazio, o segundo com um zero, como o Chrome. */
        static const unsigned char zero = 0;
        *out = (uintptr_t)arg ? &zero : NULL;
        *outlen = (uintptr_t)arg ? 1 : 0;
    }
    return 1;
}

/* ECH de mentira: parece um ECH de verdade (HPKE X25519, HKDF-SHA256, AES-128-GCM),
 * com chave e conteúdo sorteados. O servidor não consegue abrir e segue com o
 * ClientHello de fora, que é o de verdade. */
static int add_ech(SSL *s, unsigned int type, unsigned int ctx, const unsigned char **out, size_t *outlen, X509 *x,
                   size_t chain, int *al, void *arg) {
    (void)s, (void)type, (void)ctx, (void)x, (void)chain, (void)al, (void)arg;
    unsigned char sz = 0;
    if (RAND_bytes(&sz, 1) != 1) sz = 0;
    size_t payload = 128 + 32 * (size_t)(sz % 4) + 16;
    size_t n = 1 + 2 + 2 + 1 + 2 + 32 + 2 + payload;
    unsigned char *b = OPENSSL_malloc(n);
    if (!b) return 0;
    unsigned char *p = b;
    *p++ = 0;                     /* outer */
    *p++ = 0, *p++ = 1;           /* HKDF-SHA256 */
    *p++ = 0, *p++ = 1;           /* AES-128-GCM */
    if (RAND_bytes(p, 1) != 1) *p = 0;
    p++;                          /* config_id */
    *p++ = 0, *p++ = 32;          /* enc */
    if (RAND_bytes(p, 32) != 1) memset(p, 0x5a, 32);
    p += 32;
    *p++ = (unsigned char)(payload >> 8), *p++ = (unsigned char)payload;
    if (RAND_bytes(p, (int)payload) != 1) memset(p, 0xa5, payload);
    *out = b;
    *outlen = n;
    return 1;
}

static void free_ech(SSL *s, unsigned int type, unsigned int ctx, const unsigned char *out, void *arg) {
    (void)s, (void)type, (void)ctx, (void)arg;
    OPENSSL_free((void *)out);
}

/* A resposta do servidor nas EncryptedExtensions. retry_configs do ECH: aceita e
 * ignora, como o Chrome com um ECH de mentira. ALPS aceito: esta conexão não vai
 * terminar (ver `alps_body`), as próximas saem sem ele. */
static int accept_any(SSL *s, unsigned int type, unsigned int ctx, const unsigned char *in, size_t inlen, X509 *x,
                      size_t chain, int *al, void *arg) {
    (void)s, (void)ctx, (void)in, (void)inlen, (void)x, (void)chain, (void)al, (void)arg;
    if (type == EXT_ALPS) alps_off = 1;
    return 1;
}

/* O ClientHello que este perfil manda para o discord.com (só a mensagem do aperto de
 * mão, sem o cabeçalho do registro), montado na memória, sem rede: o teste
 * (src/net/tls_ja4.zig) calcula o JA4 dele. -1: não deu. */
int larper_tls_client_hello(unsigned char *out, int cap) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) return -1;
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    larper_tls_chrome(ctx, 0);
    SSL *s = SSL_new(ctx);
    BIO *rb = BIO_new(BIO_s_mem()), *wb = BIO_new(BIO_s_mem());
    int len = -1;
    if (s && rb && wb) {
        SSL_set_bio(s, rb, wb);
        rb = wb = NULL;
        /* O que o curl põe: o nome do servidor e o ALPN do HTTPS. */
        static const unsigned char alpn[] = {2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
        SSL_set_tlsext_host_name(s, "discord.com");
        SSL_set_alpn_protos(s, alpn, sizeof alpn);
        SSL_set_connect_state(s);
        SSL_do_handshake(s);
        char *data = NULL;
        long n = BIO_get_mem_data(SSL_get_wbio(s), &data);
        if (n > 5 && (unsigned char)data[0] == 0x16) {
            int rl = ((unsigned char)data[3] << 8) | (unsigned char)data[4];
            if (rl <= n - 5 && rl <= cap) {
                memcpy(out, data + 5, (size_t)rl);
                len = rl;
            }
        }
    }
    BIO_free(rb);
    BIO_free(wb);
    SSL_free(s);
    SSL_CTX_free(ctx);
    return len;
}

/* O OpenSSL que está rodando (OPENSSL_VERSION_NUMBER: 0x30500000 é o 3.5). */
unsigned long larper_tls_openssl_version(void) { return OpenSSL_version_num(); }

/* --tls-fingerprint: o site que mostra a impressão não é do Discord, mas a medida é a
 * que o Discord vê. */
void larper_tls_alps_everywhere(void) { alps_everywhere = 1; }
/* Algum servidor aceitou o ALPS (e a conexão dele caiu): o --tls-fingerprint avisa. */
int larper_tls_alps_refused(void) { return alps_off; }

/* 0 = kapali, 1 = Akilli TCP SNI bolme (yönetici gerektirmez), 2 = Sert TLS kayit + TCP bolme. */
static volatile int dpi_split_mode = 1;
static BIO_METHOD *dpi_bio_meth = NULL;

void larper_dpi_set_mode(int mode) {
    if (mode < 0) mode = 0;
    if (mode > 2) mode = 2;
    dpi_split_mode = mode;
}

int larper_dpi_get_mode(void) { return dpi_split_mode; }

static void dpi_pause_1ms(void) {
#ifdef _WIN32
    Sleep(1);
#else
    struct timespec ts = {0, 1000000L};
    nanosleep(&ts, NULL);
#endif
}

static int find_sni_mid(const unsigned char *p, int len) {
    /* TLS record (5) + handshake hdr (4) + version (2) + random (32) = 43 */
    if (len < 48) return len / 2;
    int pos = 43;
    int sid = p[pos];
    pos += 1 + sid;
    if (pos + 2 > len) return len / 2;
    int cs = ((int)p[pos] << 8) | p[pos + 1];
    pos += 2 + cs;
    if (pos + 1 > len) return len / 2;
    int cm = p[pos];
    pos += 1 + cm;
    if (pos + 2 > len) return len / 2;
    int ext_len = ((int)p[pos] << 8) | p[pos + 1];
    pos += 2;
    int ext_end = pos + ext_len;
    if (ext_end > len) ext_end = len;
    while (pos + 4 <= ext_end) {
        int etype = ((int)p[pos] << 8) | p[pos + 1];
        int elen = ((int)p[pos + 2] << 8) | p[pos + 3];
        if (pos + 4 + elen > ext_end) break;
        if (etype == 0 && elen >= 6) {
            /* 2B list len + 1B type + 2B name len = 5B -> ortadan bol. */
            int nlen = ((int)p[pos + 7] << 8) | p[pos + 8];
            int mid = pos + 9 + nlen / 2;
            if (mid > 9 && mid < len - 2) return mid;
        }
        pos += 4 + elen;
    }
    return len / 2;
}

typedef struct {
    int mode;
    int hello_done;
    int rec_len;
    int cut1;
    int cut2;
    int off;
    unsigned char rec_buf[4096];
} DpiBioState;

static int dpi_bio_create(BIO *b) {
    DpiBioState *st = OPENSSL_zalloc(sizeof(DpiBioState));
    if (!st) return 0;
    BIO_set_data(b, st);
    BIO_set_init(b, 1);
    return 1;
}

static int dpi_bio_destroy(BIO *b) {
    DpiBioState *st = BIO_get_data(b);
    if (st) {
        OPENSSL_free(st);
        BIO_set_data(b, NULL);
    }
    BIO_set_init(b, 0);
    return 1;
}

static int dpi_bio_read(BIO *b, char *out, int outl) {
    BIO *next = BIO_next(b);
    if (!next) return 0;
    int r = BIO_read(next, out, outl);
    BIO_clear_retry_flags(b);
    BIO_copy_next_retry(b);
    return r;
}

static int dpi_bio_puts(BIO *b, const char *str) {
    BIO *next = BIO_next(b);
    return (next && str) ? BIO_puts(next, str) : 0;
}

static long dpi_bio_ctrl(BIO *b, int cmd, long num, void *ptr) {
    BIO *next = BIO_next(b);
    if (!next) return 0;
    return BIO_ctrl(next, cmd, num, ptr);
}

static int dpi_bio_write(BIO *b, const char *in, int inl) {
    BIO *next = BIO_next(b);
    DpiBioState *st = BIO_get_data(b);
    if (!next || !in || inl <= 0) return 0;
    if (!st || st->hello_done || st->mode <= 0) {
        int r = BIO_write(next, in, inl);
        BIO_clear_retry_flags(b);
        BIO_copy_next_retry(b);
        return r;
    }

    const unsigned char *u = (const unsigned char *)in;
    if (st->off == 0) {
        /* Ilk paket TLS ClientHello degilse dogrudan gecir. */
        if (inl < 48 || u[0] != 0x16 || u[1] != 0x03 || u[5] != 0x01) {
            st->hello_done = 1;
            int r = BIO_write(next, in, inl);
            BIO_clear_retry_flags(b);
            BIO_copy_next_retry(b);
            return r;
        }
        int mid = find_sni_mid(u, inl);
        if (st->mode == 2 && mid > 9 && inl + 5 <= (int)sizeof(st->rec_buf)) {
            int p1 = mid - 5;
            int p2 = inl - mid;
            st->rec_buf[0] = 0x16;
            st->rec_buf[1] = 0x03;
            st->rec_buf[2] = 0x01;
            st->rec_buf[3] = (unsigned char)(p1 >> 8);
            st->rec_buf[4] = (unsigned char)p1;
            memcpy(st->rec_buf + 5, u + 5, (size_t)p1);
            int o2 = 5 + p1;
            st->rec_buf[o2 + 0] = 0x16;
            st->rec_buf[o2 + 1] = 0x03;
            st->rec_buf[o2 + 2] = 0x01;
            st->rec_buf[o2 + 3] = (unsigned char)(p2 >> 8);
            st->rec_buf[o2 + 4] = (unsigned char)p2;
            memcpy(st->rec_buf + o2 + 5, u + mid, (size_t)p2);
            st->rec_len = o2 + 5 + p2;
            st->cut1 = 7;
            st->cut2 = o2;
        } else {
            st->rec_len = 0;
            st->cut1 = 2;
            st->cut2 = mid;
        }
    }

    const char *src = st->rec_len > 0 ? (const char *)st->rec_buf : in;
    int total = st->rec_len > 0 ? st->rec_len : inl;
    while (st->off < total) {
        int end = st->off < st->cut1 ? st->cut1 : (st->off < st->cut2 ? st->cut2 : total);
        int w = BIO_write(next, src + st->off, end - st->off);
        if (w <= 0) {
            BIO_clear_retry_flags(b);
            BIO_copy_next_retry(b);
            return w;
        }
        st->off += w;
        if (st->off < total && (st->off == st->cut1 || st->off == st->cut2)) dpi_pause_1ms();
    }
    st->hello_done = 1;
    return inl;
}

static BIO_METHOD *ensure_dpi_bio_method(void) {
    BIO_METHOD *cur = __atomic_load_n(&dpi_bio_meth, __ATOMIC_ACQUIRE);
    if (cur) return cur;
    BIO_METHOD *m = BIO_meth_new(BIO_TYPE_FILTER, "larper_dpi");
    if (!m) return NULL;
    BIO_meth_set_write(m, dpi_bio_write);
    BIO_meth_set_read(m, dpi_bio_read);
    BIO_meth_set_puts(m, dpi_bio_puts);
    BIO_meth_set_ctrl(m, dpi_bio_ctrl);
    BIO_meth_set_create(m, dpi_bio_create);
    BIO_meth_set_destroy(m, dpi_bio_destroy);
    BIO_METHOD *expected = NULL;
    if (!__atomic_compare_exchange_n(&dpi_bio_meth, &expected, m, 0, __ATOMIC_RELEASE, __ATOMIC_ACQUIRE)) {
        BIO_meth_free(m);
        return expected;
    }
    return m;
}

static void dpi_info_cb(const SSL *ssl_c, int where, int ret) {
    (void)ret;
    if ((where & SSL_CB_HANDSHAKE_START) == 0) return;
    int mode = __atomic_load_n(&dpi_split_mode, __ATOMIC_RELAXED);
    if (mode <= 0) return;
    SSL *s = (SSL *)ssl_c;
    if (!SSL_get_servername(s, TLSEXT_NAMETYPE_host_name)) return;
    BIO *wbio = SSL_get_wbio(s);
    if (!wbio) return;
    const char *mname = BIO_method_name(wbio);
    if (mname && strcmp(mname, "larper_dpi") == 0) return;
    BIO_METHOD *meth = ensure_dpi_bio_method();
    if (!meth) return;
    int fd = -1;
    if (BIO_get_fd(wbio, &fd) <= 0 || fd < 0) return;
    int one = 1;
    (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof(one));
    BIO *f = BIO_new(meth);
    if (!f) return;
    DpiBioState *st = BIO_get_data(f);
    if (st) st->mode = mode;
    BIO_up_ref(wbio);
    BIO_push(f, wbio);
    SSL_set0_wbio(s, f);
}

/* `h1_only`: a conexão só oferece HTTP/1.1 (o gateway e a voz, que são WebSocket, ou um
 * curl sem HTTP/2), e o ALPS, que é do h2, não vai. */
int larper_tls_chrome(void *ssl_ctx, int h1_only) {
    SSL_CTX *ctx = ssl_ctx;
    if (!ctx) return 0;
    int ok = 1;
    ok &= SSL_CTX_set_cipher_list(ctx, ciphers12);
    ok &= SSL_CTX_set_ciphersuites(ctx, ciphers13);
    if (!SSL_CTX_set1_groups_list(ctx, groups)) ok &= SSL_CTX_set1_groups_list(ctx, groups_old);
    if (!SSL_CTX_set1_sigalgs_list(ctx, sigalgs)) ok &= SSL_CTX_set1_sigalgs_list(ctx, sigalgs_old);
    /* O Chrome não manda encrypt_then_mac nem post_handshake_auth, e manda o
     * session_ticket vazio. */
    SSL_CTX_set_options(ctx, SSL_OP_NO_ENCRYPT_THEN_MAC);
    SSL_CTX_clear_options(ctx, SSL_OP_NO_TICKET);
    SSL_CTX_set_post_handshake_auth(ctx, 0);
#ifndef OPENSSL_NO_OCSP
    SSL_CTX_set_tlsext_status_type(ctx, TLSEXT_STATUSTYPE_ocsp);
#endif
#ifndef OPENSSL_NO_CT
    SSL_CTX_enable_ct(ctx, SSL_CT_VALIDATION_PERMISSIVE);
#endif
#ifdef TLSEXT_comp_cert_brotli
    /* Certificado comprimido: só brotli (o OpenSSL ofereceria zlib e zstd também). */
    int comp[] = {TLSEXT_comp_cert_brotli};
    SSL_CTX_set1_cert_comp_preference(ctx, comp, 1);
#endif
    unsigned g1 = grease(0), g2 = grease(g1);
    unsigned ee = SSL_EXT_CLIENT_HELLO | SSL_EXT_TLS1_3_ENCRYPTED_EXTENSIONS;
    /* O servidor também manda GREASE (no ticket de sessão, no certificado), com o valor
     * dele: se cair num dos nossos, o OpenSSL só aceita onde ele foi registrado. Sem
     * isso, ~1 conexão em 8 caía com "bad extension" depois do aperto de mão. */
    unsigned cli = SSL_EXT_CLIENT_HELLO | SSL_EXT_TLS1_3_NEW_SESSION_TICKET | SSL_EXT_TLS1_3_CERTIFICATE;
    if (!h1_only) SSL_CTX_add_custom_ext(ctx, EXT_ALPS, ee, add_fixed, NULL, NULL, accept_any, NULL);
    SSL_CTX_add_custom_ext(ctx, EXT_ECH, ee, add_ech, free_ech, NULL, accept_any, NULL);
    SSL_CTX_add_custom_ext(ctx, g1, cli, add_fixed, NULL, (void *)(uintptr_t)0, accept_any, NULL);
    SSL_CTX_add_custom_ext(ctx, g2, cli, add_fixed, NULL, (void *)(uintptr_t)1, accept_any, NULL);
    SSL_CTX_set_info_callback(ctx, dpi_info_cb);
    return ok;
}
