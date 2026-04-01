/*
 * snapshot_grabber — JPEG snapshot from VI frame via libjpeg-turbo
 *
 * Grabs a raw NV12 frame from VI channel 0 (owned by lp_app),
 * converts to JPEG using libjpeg-turbo (statically linked).
 *
 * No VENC channel needed — the RV1103 only has 2 (both used by lp_app).
 *
 * Target: Rockchip RV1103 (ARM Cortex-A7), uclibc, dynamic link.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <jpeglib.h>

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
#define JPEG_QUALITY    95

/*
 * Encode NV12 (YUV420SP) to JPEG using libjpeg-turbo raw data API.
 *
 * NV12 layout: Y plane (width*height) followed by interleaved UV plane
 * (width*height/2, alternating Cb/Cr bytes).
 *
 * libjpeg raw data API expects separate Y, Cb, Cr plane pointers in
 * MCU rows (16 lines of Y, 8 lines of Cb/Cr for 4:2:0).
 *
 * Returns JPEG size in bytes, or -1 on error.
 */
static int nv12_to_jpeg(const unsigned char *y_plane, const unsigned char *uv_plane,
                         int width, int height, int stride,
                         unsigned char **jpeg_out, unsigned long *jpeg_out_size) {
    struct jpeg_compress_struct cinfo;
    struct jpeg_error_mgr jerr;
    int row, i;

    /* Cb/Cr deinterleave buffers (one MCU height = 8 rows of chroma) */
    int cw = (width + 1) / 2;   /* chroma width */
    unsigned char *cb_buf = (unsigned char *)malloc(cw * 8);
    unsigned char *cr_buf = (unsigned char *)malloc(cw * 8);
    if (!cb_buf || !cr_buf) {
        free(cb_buf);
        free(cr_buf);
        return -1;
    }

    cinfo.err = jpeg_std_error(&jerr);
    jpeg_create_compress(&cinfo);

    /* Output to memory buffer */
    *jpeg_out = NULL;
    *jpeg_out_size = 0;
    jpeg_mem_dest(&cinfo, jpeg_out, jpeg_out_size);

    cinfo.image_width = width;
    cinfo.image_height = height;
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_YCbCr;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, JPEG_QUALITY, TRUE);

    /* Configure for raw YCbCr 4:2:0 input */
    cinfo.raw_data_in = TRUE;
    cinfo.comp_info[0].h_samp_factor = 2;  /* Y: 2x2 */
    cinfo.comp_info[0].v_samp_factor = 2;
    cinfo.comp_info[1].h_samp_factor = 1;  /* Cb: 1x1 */
    cinfo.comp_info[1].v_samp_factor = 1;
    cinfo.comp_info[2].h_samp_factor = 1;  /* Cr: 1x1 */
    cinfo.comp_info[2].v_samp_factor = 1;

    jpeg_start_compress(&cinfo, TRUE);

    /* Process in MCU rows: 16 lines of Y, 8 lines of Cb/Cr */
    JSAMPROW y_rows[16], cb_rows[8], cr_rows[8];
    JSAMPARRAY planes[3] = { y_rows, cb_rows, cr_rows };

    while (cinfo.next_scanline < cinfo.image_height) {
        int mcu_y = cinfo.next_scanline;

        /* Set up Y row pointers (16 rows) */
        for (i = 0; i < 16; i++) {
            int y = mcu_y + i;
            if (y >= height) y = height - 1;
            y_rows[i] = (JSAMPROW)(y_plane + y * stride);
        }

        /* Deinterleave NV12 UV into separate Cb/Cr rows (8 rows) */
        for (row = 0; row < 8; row++) {
            int cy = (mcu_y / 2) + row;
            if (cy >= height / 2) cy = height / 2 - 1;
            const unsigned char *uv_row = uv_plane + cy * stride;
            for (i = 0; i < cw; i++) {
                cb_buf[row * cw + i] = uv_row[i * 2];
                cr_buf[row * cw + i] = uv_row[i * 2 + 1];
            }
            cb_rows[row] = cb_buf + row * cw;
            cr_rows[row] = cr_buf + row * cw;
        }

        jpeg_write_raw_data(&cinfo, planes, 16);
    }

    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    free(cb_buf);
    free(cr_buf);

    return (int)(*jpeg_out_size);
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

    /* Encode NV12 to JPEG using libjpeg-turbo (allocates output buffer) */
    unsigned char *jpeg_buf = NULL;
    unsigned long jpeg_size = 0;
    int result = nv12_to_jpeg(y_plane, uv_plane, width, height, stride,
                               &jpeg_buf, &jpeg_size);

    /* Release VI frame immediately (don't hold it during file write) */
    RK_MPI_VI_ReleaseChnFrame(VI_PIPE_ID, VI_CHN_ID, &stViFrame);

    if (result <= 0 || !jpeg_buf) {
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

    fprintf(stderr, "snapshot_grabber: %lu bytes -> %s\n", jpeg_size, output_path);
    return cleanup_and_exit(0);
}
