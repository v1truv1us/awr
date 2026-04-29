/**
 * stb_image_impl.c — single translation unit for stb_image.
 *
 * Mirrors the BoringSSL `tls_awr_shim.c` discipline: vendor a third-party
 * library by compiling exactly one .c file that pulls the header's
 * implementation. All other modules consume the public API only.
 *
 * Build flags (per spec/subspecs/rendering.md §3.1):
 *   STBI_NO_STDIO   — AWR feeds bytes from the network, never from disk.
 *                      Removes fopen/fread; smaller binary, no syscalls.
 *   STBI_NO_HDR     — terminal output cannot show high-dynamic-range data;
 *                      drop the float decoder path.
 *   STBI_NO_LINEAR  — no linear-space (gamma=1.0) decoding needed; the
 *                      sRGB bytes that come out of stbi_load_from_memory
 *                      are what we hand to the encoder.
 */

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR

#include "stb_image.h"
