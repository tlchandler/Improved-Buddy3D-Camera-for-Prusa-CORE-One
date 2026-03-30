/*
 * snapshot_grabber — JPEG snapshot from VI frame via software encoding
 *
 * Grabs a raw NV12 frame from VI channel 0 (owned by lp_app),
 * converts to JPEG using minimal software encoder, writes to file.
 *
 * No VENC channel needed — the RV1103 only has 2 (both used by lp_app).
 * Instead we do a lightweight software NV12→JPEG conversion.
 *
 * Target: Rockchip RV1103 (ARM Cortex-A7), uclibc, dynamic link.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#include "rk_type.h"
#include "rk_common.h"
#include "rk_comm_video.h"
#include "rk_comm_vi.h"
#include "rk_comm_mb.h"
#include "rk_mpi_sys.h"
#include "rk_mpi_vi.h"
#include "rk_mpi_mb.h"

#define VI_PIPE_ID      0
#define VI_CHN_ID       0
#define VI_TIMEOUT_MS   3000
#define DEFAULT_OUTPUT  "/tmp/buddy_snapshot.jpg"

/*
 * Minimal JPEG encoder for NV12 (YUV420SP) input.
 * No external library needed — generates valid JFIF files.
 * Quality is modest but sufficient for preview thumbnails.
 */

/* Standard JPEG luminance quantization table (quality ~75) */
static const unsigned char std_lum_qt[64] = {
     8,  6,  5,  8, 12, 20, 26, 31,
     6,  6,  7, 10, 13, 29, 30, 28,
     7,  7,  8, 12, 20, 29, 35, 28,
     7,  9, 11, 15, 26, 44, 40, 31,
     9, 11, 19, 28, 34, 55, 52, 39,
    12, 18, 28, 32, 41, 52, 57, 46,
    25, 32, 39, 44, 52, 61, 60, 51,
    36, 46, 48, 49, 56, 50, 52, 50
};

/* Standard JPEG chrominance quantization table */
static const unsigned char std_chr_qt[64] = {
     9,  9, 12, 24, 50, 50, 50, 50,
     9, 11, 13, 33, 50, 50, 50, 50,
    12, 13, 28, 50, 50, 50, 50, 50,
    24, 33, 50, 50, 50, 50, 50, 50,
    50, 50, 50, 50, 50, 50, 50, 50,
    50, 50, 50, 50, 50, 50, 50, 50,
    50, 50, 50, 50, 50, 50, 50, 50,
    50, 50, 50, 50, 50, 50, 50, 50
};

/* Zigzag order */
static const int zz[64] = {
     0, 1, 8,16, 9, 2, 3,10,
    17,24,32,25,18,11, 4, 5,
    12,19,26,33,40,48,41,34,
    27,20,13, 6, 7,14,21,28,
    35,42,49,56,57,50,43,36,
    29,22,15,23,30,37,44,51,
    58,59,52,45,38,31,39,46,
    53,60,61,54,47,55,62,63
};

/* DC Huffman tables (luminance/chrominance) */
static const unsigned char dc_lum_bits[17] = {0,0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0};
static const unsigned char dc_lum_val[12]  = {0,1,2,3,4,5,6,7,8,9,10,11};
static const unsigned char dc_chr_bits[17] = {0,0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0};
static const unsigned char dc_chr_val[12]  = {0,1,2,3,4,5,6,7,8,9,10,11};

/* AC Huffman tables */
static const unsigned char ac_lum_bits[17] = {0,0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d};
static const unsigned char ac_lum_val[162] = {
    0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,
    0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,
    0xd1,0xf0,0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,0x17,0x18,0x19,0x1a,0x25,
    0x26,0x27,0x28,0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,
    0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,
    0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x83,
    0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,
    0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,
    0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,
    0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,
    0xe9,0xea,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa
};
static const unsigned char ac_chr_bits[17] = {0,0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,0x77};
static const unsigned char ac_chr_val[162] = {
    0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,0x61,
    0x71,0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91,0xa1,0xb1,0xc1,0x09,0x23,0x33,
    0x52,0xf0,0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34,0xe1,0x25,0xf1,0x17,0x18,
    0x19,0x1a,0x26,0x27,0x28,0x29,0x2a,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,
    0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,
    0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,
    0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,
    0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,
    0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,
    0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,
    0xe8,0xe9,0xea,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa
};

/* JPEG writer state */
typedef struct {
    unsigned char *buf;
    int buf_size;
    int pos;
    unsigned int bit_buf;
    int bit_cnt;
} JpegWriter;

/* Huffman code table (precomputed from bits/val) */
typedef struct {
    unsigned short code[256];
    unsigned char  len[256];
} HuffTable;

static void jw_init(JpegWriter *jw, unsigned char *buf, int size) {
    jw->buf = buf; jw->buf_size = size; jw->pos = 0;
    jw->bit_buf = 0; jw->bit_cnt = 0;
}

static void jw_byte(JpegWriter *jw, unsigned char b) {
    if (jw->pos < jw->buf_size) jw->buf[jw->pos++] = b;
}

static void jw_word(JpegWriter *jw, unsigned short w) {
    jw_byte(jw, w >> 8); jw_byte(jw, w & 0xff);
}

static void jw_bits(JpegWriter *jw, unsigned int bits, int nbits) {
    jw->bit_buf = (jw->bit_buf << nbits) | (bits & ((1u << nbits) - 1));
    jw->bit_cnt += nbits;
    while (jw->bit_cnt >= 8) {
        unsigned char b = (jw->bit_buf >> (jw->bit_cnt - 8)) & 0xff;
        jw_byte(jw, b);
        if (b == 0xff) jw_byte(jw, 0x00); /* byte stuffing */
        jw->bit_cnt -= 8;
    }
}

static void jw_flush_bits(JpegWriter *jw) {
    if (jw->bit_cnt > 0) {
        jw_bits(jw, 0x7f, 7); /* pad with 1s */
    }
    jw->bit_buf = 0; jw->bit_cnt = 0;
}

static void build_hufftable(HuffTable *ht, const unsigned char *bits, const unsigned char *val) {
    int i, j, k = 0;
    unsigned short code = 0;
    memset(ht, 0, sizeof(*ht));
    for (i = 1; i <= 16; i++) {
        for (j = 0; j < bits[i]; j++) {
            ht->code[val[k]] = code;
            ht->len[val[k]]  = i;
            k++; code++;
        }
        code <<= 1;
    }
}

static HuffTable ht_dc_lum, ht_ac_lum, ht_dc_chr, ht_ac_chr;

static void init_hufftables(void) {
    build_hufftable(&ht_dc_lum, dc_lum_bits, dc_lum_val);
    build_hufftable(&ht_ac_lum, ac_lum_bits, ac_lum_val);
    build_hufftable(&ht_dc_chr, dc_chr_bits, dc_chr_val);
    build_hufftable(&ht_ac_chr, ac_chr_bits, ac_chr_val);
}

/* Write DHT marker segment */
static void jw_write_dht(JpegWriter *jw, int cls, int id,
                          const unsigned char *bits, const unsigned char *val) {
    int i, count = 0;
    for (i = 1; i <= 16; i++) count += bits[i];
    jw_word(jw, 0xffc4);
    jw_word(jw, 3 + 16 + count);
    jw_byte(jw, (cls << 4) | id);
    for (i = 1; i <= 16; i++) jw_byte(jw, bits[i]);
    for (i = 0; i < count; i++) jw_byte(jw, val[i]);
}

/* Forward DCT (slow but small — only runs on 8x8 blocks) */
static void fdct(int *block) {
    int i, tmp0, tmp1, tmp2, tmp3, tmp4, tmp5, tmp6, tmp7;
    int tmp10, tmp11, tmp12, tmp13;
    int z1, z2, z3, z4, z5;
    int *dp;
    /* Rows */
    for (dp = block, i = 0; i < 8; i++, dp += 8) {
        tmp0 = dp[0] + dp[7]; tmp7 = dp[0] - dp[7];
        tmp1 = dp[1] + dp[6]; tmp6 = dp[1] - dp[6];
        tmp2 = dp[2] + dp[5]; tmp5 = dp[2] - dp[5];
        tmp3 = dp[3] + dp[4]; tmp4 = dp[3] - dp[4];
        tmp10 = tmp0 + tmp3; tmp13 = tmp0 - tmp3;
        tmp11 = tmp1 + tmp2; tmp12 = tmp1 - tmp2;
        dp[0] = (tmp10 + tmp11) << 2;
        dp[4] = (tmp10 - tmp11) << 2;
        z1 = (tmp12 + tmp13) * 4433 >> 12;
        dp[2] = z1 + (tmp13 * 6270 >> 12);
        dp[6] = z1 - (tmp12 * 15137 >> 12);
        z1 = (tmp4 + tmp7); z2 = (tmp5 + tmp6);
        z3 = (tmp4 + tmp6); z4 = (tmp5 + tmp7);
        z5 = (z3 + z4) * 9633 >> 12;
        tmp4 = tmp4 * 2446 >> 12; tmp5 = tmp5 * 16819 >> 12;
        tmp6 = tmp6 * 25172 >> 12; tmp7 = tmp7 * 12299 >> 12;
        z1 = z1 * -7373 >> 12; z2 = z2 * -20995 >> 12;
        z3 = z3 * -16069 >> 12; z4 = z4 * -3196 >> 12;
        z3 += z5; z4 += z5;
        dp[7] = tmp4 + z1 + z3; dp[5] = tmp5 + z2 + z4;
        dp[3] = tmp6 + z2 + z3; dp[1] = tmp7 + z1 + z4;
    }
    /* Columns */
    for (dp = block, i = 0; i < 8; i++, dp++) {
        tmp0 = dp[0] + dp[56]; tmp7 = dp[0] - dp[56];
        tmp1 = dp[8] + dp[48]; tmp6 = dp[8] - dp[48];
        tmp2 = dp[16]+ dp[40]; tmp5 = dp[16]- dp[40];
        tmp3 = dp[24]+ dp[32]; tmp4 = dp[24]- dp[32];
        tmp10 = tmp0 + tmp3; tmp13 = tmp0 - tmp3;
        tmp11 = tmp1 + tmp2; tmp12 = tmp1 - tmp2;
        dp[0]  = (tmp10 + tmp11 + 4) >> 3;
        dp[32] = (tmp10 - tmp11 + 4) >> 3;
        z1 = (tmp12 + tmp13) * 4433 >> 12;
        dp[16] = (z1 + (tmp13 * 6270 >> 12) + 4) >> 3;
        dp[48] = (z1 - (tmp12 * 15137 >> 12) + 4) >> 3;
        z1 = tmp4 + tmp7; z2 = tmp5 + tmp6;
        z3 = tmp4 + tmp6; z4 = tmp5 + tmp7;
        z5 = (z3 + z4) * 9633 >> 12;
        tmp4 = tmp4 * 2446 >> 12; tmp5 = tmp5 * 16819 >> 12;
        tmp6 = tmp6 * 25172 >> 12; tmp7 = tmp7 * 12299 >> 12;
        z1 = z1 * -7373 >> 12; z2 = z2 * -20995 >> 12;
        z3 = z3 * -16069 >> 12; z4 = z4 * -3196 >> 12;
        z3 += z5; z4 += z5;
        dp[56] = (tmp4 + z1 + z3 + 4) >> 3;
        dp[40] = (tmp5 + z2 + z4 + 4) >> 3;
        dp[24] = (tmp6 + z2 + z3 + 4) >> 3;
        dp[8]  = (tmp7 + z1 + z4 + 4) >> 3;
    }
}

/* Encode one 8x8 block */
static void encode_block(JpegWriter *jw, int *block, int *prev_dc,
                          HuffTable *ht_dc, HuffTable *ht_ac,
                          const unsigned char *qt) {
    int i, k, tmp, nbits, diff;
    /* Quantize */
    for (i = 0; i < 64; i++) block[i] = (block[i] + (qt[i] >> 1)) / (int)qt[i];
    /* DC */
    diff = block[0] - *prev_dc;
    *prev_dc = block[0];
    if (diff == 0) {
        jw_bits(jw, ht_dc->code[0], ht_dc->len[0]);
    } else {
        tmp = diff < 0 ? -diff : diff;
        nbits = 0; while (tmp) { nbits++; tmp >>= 1; }
        jw_bits(jw, ht_dc->code[nbits], ht_dc->len[nbits]);
        if (diff < 0) diff += (1 << nbits) - 1;
        jw_bits(jw, diff, nbits);
    }
    /* AC */
    int nzeros = 0;
    for (k = 1; k < 64; k++) {
        int val = block[zz[k]];
        if (val == 0) { nzeros++; continue; }
        while (nzeros >= 16) {
            jw_bits(jw, ht_ac->code[0xf0], ht_ac->len[0xf0]);
            nzeros -= 16;
        }
        tmp = val < 0 ? -val : val;
        nbits = 0; while (tmp) { nbits++; tmp >>= 1; }
        jw_bits(jw, ht_ac->code[(nzeros << 4) | nbits],
                     ht_ac->len[(nzeros << 4) | nbits]);
        if (val < 0) val += (1 << nbits) - 1;
        jw_bits(jw, val, nbits);
        nzeros = 0;
    }
    if (nzeros > 0) jw_bits(jw, ht_ac->code[0], ht_ac->len[0]); /* EOB */
}

/*
 * Encode NV12 (YUV420SP) to JPEG.
 * Returns JPEG size in bytes, or -1 on error.
 */
static int nv12_to_jpeg(const unsigned char *y_plane, const unsigned char *uv_plane,
                         int width, int height, int stride,
                         unsigned char *jpeg_buf, int jpeg_buf_size) {
    JpegWriter jw;
    int dc_y = 0, dc_cb = 0, dc_cr = 0;
    int bx, by;
    int block[64];

    jw_init(&jw, jpeg_buf, jpeg_buf_size);
    init_hufftables();

    /* SOI */
    jw_word(&jw, 0xffd8);
    /* APP0 (JFIF) */
    jw_word(&jw, 0xffe0);
    jw_word(&jw, 16); jw_byte(&jw,'J'); jw_byte(&jw,'F'); jw_byte(&jw,'I'); jw_byte(&jw,'F'); jw_byte(&jw,0);
    jw_byte(&jw,1); jw_byte(&jw,1); jw_byte(&jw,0);
    jw_word(&jw,1); jw_word(&jw,1); jw_byte(&jw,0); jw_byte(&jw,0);
    /* DQT lum */
    jw_word(&jw, 0xffdb); jw_word(&jw, 67); jw_byte(&jw, 0);
    for (int i = 0; i < 64; i++) jw_byte(&jw, std_lum_qt[zz[i]]);
    /* DQT chr */
    jw_word(&jw, 0xffdb); jw_word(&jw, 67); jw_byte(&jw, 1);
    for (int i = 0; i < 64; i++) jw_byte(&jw, std_chr_qt[zz[i]]);
    /* SOF0 (Baseline, YCbCr 4:2:0) */
    jw_word(&jw, 0xffc0); jw_word(&jw, 17); jw_byte(&jw, 8);
    jw_word(&jw, height); jw_word(&jw, width);
    jw_byte(&jw, 3); /* 3 components */
    jw_byte(&jw, 1); jw_byte(&jw, 0x22); jw_byte(&jw, 0); /* Y: 2x2, qt0 */
    jw_byte(&jw, 2); jw_byte(&jw, 0x11); jw_byte(&jw, 1); /* Cb: 1x1, qt1 */
    jw_byte(&jw, 3); jw_byte(&jw, 0x11); jw_byte(&jw, 1); /* Cr: 1x1, qt1 */
    /* DHT */
    jw_write_dht(&jw, 0, 0, dc_lum_bits, dc_lum_val);
    jw_write_dht(&jw, 1, 0, ac_lum_bits, ac_lum_val);
    jw_write_dht(&jw, 0, 1, dc_chr_bits, dc_chr_val);
    jw_write_dht(&jw, 1, 1, ac_chr_bits, ac_chr_val);
    /* SOS */
    jw_word(&jw, 0xffda); jw_word(&jw, 12); jw_byte(&jw, 3);
    jw_byte(&jw, 1); jw_byte(&jw, 0x00); /* Y: DC0/AC0 */
    jw_byte(&jw, 2); jw_byte(&jw, 0x11); /* Cb: DC1/AC1 */
    jw_byte(&jw, 3); jw_byte(&jw, 0x11); /* Cr: DC1/AC1 */
    jw_byte(&jw, 0); jw_byte(&jw, 63); jw_byte(&jw, 0);

    /* Encode MCUs (16x16 for 4:2:0) */
    for (by = 0; by < height; by += 16) {
        for (bx = 0; bx < width; bx += 16) {
            /* 4 Y blocks (8x8 each in a 16x16 MCU) */
            int yy, xx;
            for (yy = 0; yy < 2; yy++) {
                for (xx = 0; xx < 2; xx++) {
                    int r, c;
                    for (r = 0; r < 8; r++) {
                        int py = by + yy * 8 + r;
                        if (py >= height) py = height - 1;
                        for (c = 0; c < 8; c++) {
                            int px = bx + xx * 8 + c;
                            if (px >= width) px = width - 1;
                            block[r * 8 + c] = (int)y_plane[py * stride + px] - 128;
                        }
                    }
                    fdct(block);
                    encode_block(&jw, block, &dc_y, &ht_dc_lum, &ht_ac_lum, std_lum_qt);
                }
            }
            /* Cb block */
            {
                int r, c;
                for (r = 0; r < 8; r++) {
                    int py = (by / 2) + r;
                    if (py >= height / 2) py = height / 2 - 1;
                    for (c = 0; c < 8; c++) {
                        int px = (bx / 2) + c;
                        if (px >= width / 2) px = width / 2 - 1;
                        block[r * 8 + c] = (int)uv_plane[py * stride + px * 2] - 128;
                    }
                }
                fdct(block);
                encode_block(&jw, block, &dc_cb, &ht_dc_chr, &ht_ac_chr, std_chr_qt);
            }
            /* Cr block */
            {
                int r, c;
                for (r = 0; r < 8; r++) {
                    int py = (by / 2) + r;
                    if (py >= height / 2) py = height / 2 - 1;
                    for (c = 0; c < 8; c++) {
                        int px = (bx / 2) + c;
                        if (px >= width / 2) px = width / 2 - 1;
                        block[r * 8 + c] = (int)uv_plane[py * stride + px * 2 + 1] - 128;
                    }
                }
                fdct(block);
                encode_block(&jw, block, &dc_cr, &ht_dc_chr, &ht_ac_chr, std_chr_qt);
            }
        }
    }
    jw_flush_bits(&jw);
    /* EOI */
    jw_word(&jw, 0xffd9);
    return jw.pos;
}

static int cleanup_and_exit(int code) {
    RK_MPI_SYS_Exit();
    return code;
}

int main(int argc, char *argv[]) {
    const char *output_path = DEFAULT_OUTPUT;
    if (argc >= 2) output_path = argv[1];

    RK_S32 ret;
    VIDEO_FRAME_INFO_S stViFrame;
    memset(&stViFrame, 0, sizeof(stViFrame));

    /* Init MPI (refcounted, safe even if lp_app already called it) */
    ret = RK_MPI_SYS_Init();
    if (ret != RK_SUCCESS) {
        fprintf(stderr, "RK_MPI_SYS_Init failed: 0x%x\n", ret);
        return 1;
    }

    /* Discard first frame — it may be a stale/partial buffer from the
       sensor pipeline, which causes tearing artifacts in the output. */
    ret = RK_MPI_VI_GetChnFrame(VI_PIPE_ID, VI_CHN_ID, &stViFrame, VI_TIMEOUT_MS);
    if (ret == RK_SUCCESS) {
        RK_MPI_VI_ReleaseChnFrame(VI_PIPE_ID, VI_CHN_ID, &stViFrame);
    } else {
        fprintf(stderr, "RK_MPI_VI_GetChnFrame (discard) failed: 0x%x\n", ret);
        return cleanup_and_exit(1);
    }

    /* Grab a fresh, complete frame */
    memset(&stViFrame, 0, sizeof(stViFrame));
    ret = RK_MPI_VI_GetChnFrame(VI_PIPE_ID, VI_CHN_ID, &stViFrame, VI_TIMEOUT_MS);
    if (ret != RK_SUCCESS) {
        fprintf(stderr, "RK_MPI_VI_GetChnFrame failed: 0x%x\n", ret);
        return cleanup_and_exit(1);
    }

    VIDEO_FRAME_S *frame = &stViFrame.stVFrame;
    int width  = frame->u32Width;
    int height = frame->u32Height;
    int stride = frame->u32VirWidth;

    void *vir_addr = RK_MPI_MB_Handle2VirAddr(frame->pMbBlk);
    if (!vir_addr) {
        fprintf(stderr, "RK_MPI_MB_Handle2VirAddr returned NULL\n");
        RK_MPI_VI_ReleaseChnFrame(VI_PIPE_ID, VI_CHN_ID, &stViFrame);
        return cleanup_and_exit(1);
    }

    int frame_size = stride * height * 3 / 2; /* NV12: Y + UV/2 */
    fprintf(stderr, "Frame: %dx%d stride=%d vaddr=%p size=%d\n",
            width, height, stride, vir_addr, frame_size);

    /* NV12 layout: Y plane followed by interleaved UV plane */
    const unsigned char *y_plane  = (const unsigned char *)vir_addr;
    const unsigned char *uv_plane = y_plane + stride * height;

    /* Allocate JPEG output buffer (generous: ~1 byte per pixel max) */
    int jpeg_buf_size = width * height;
    unsigned char *jpeg_buf = (unsigned char *)malloc(jpeg_buf_size);
    if (!jpeg_buf) {
        fprintf(stderr, "malloc(%d) failed\n", jpeg_buf_size);
        RK_MPI_VI_ReleaseChnFrame(VI_PIPE_ID, VI_CHN_ID, &stViFrame);
        return cleanup_and_exit(1);
    }

    /* Convert NV12 to JPEG */
    int jpeg_size = nv12_to_jpeg(y_plane, uv_plane, width, height, stride,
                                  jpeg_buf, jpeg_buf_size);

    /* Release VI frame immediately (don't hold it during file write) */
    RK_MPI_VI_ReleaseChnFrame(VI_PIPE_ID, VI_CHN_ID, &stViFrame);

    if (jpeg_size <= 0) {
        fprintf(stderr, "JPEG encode failed\n");
        free(jpeg_buf);
        return cleanup_and_exit(1);
    }

    /* Write to temp file then rename (atomic) */
    char tmp_path[512];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", output_path);
    FILE *fp = fopen(tmp_path, "wb");
    if (!fp) {
        fprintf(stderr, "Cannot open %s: %s\n", tmp_path, strerror(errno));
        free(jpeg_buf);
        return cleanup_and_exit(1);
    }
    fwrite(jpeg_buf, 1, jpeg_size, fp);
    fclose(fp);
    free(jpeg_buf);
    rename(tmp_path, output_path);

    fprintf(stderr, "snapshot_grabber: %d bytes -> %s\n", jpeg_size, output_path);
    return cleanup_and_exit(0);
}
