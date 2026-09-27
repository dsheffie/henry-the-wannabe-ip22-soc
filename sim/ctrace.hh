#ifndef __CTRACE_HH__
#define __CTRACE_HH__
/*
 * ctrace -- chunked, columnar, zstd-compressed retire trace.
 *
 * WHY THIS SHAPE (all measured on real traces from this project, not guessed):
 *   - zstd-3 runs at ~2600 MB/s while henry_tb produces ~3 MB/s of trace, so
 *     compression is free: there is no reason to hand-roll a codec for speed.
 *   - COLUMNAR beats interleaved by 2.08x on a real {asid,pc} stream (231x vs 111x).
 *     Each field compresses against its own kind: the near-constant asid column hit
 *     10062x alone but dragged the record down to 111x when interleaved with pc bytes.
 *     Our flags/dst columns behave like that asid column; only `val` has real entropy.
 *   - CHUNKED (default 1M retires) so the file is seekable without decompressing the
 *     whole stream, and a killed run still leaves every completed chunk readable --
 *     this project has lost long traces to runaway/kill before.
 *
 * FILE FORMAT (little-endian host order; each column is a standard zstd frame, so the
 * plain `zstd` CLI can decode a column blob once it has been sliced out):
 *   magic   : "R9TRACE1"                                  (8 B)
 *   chunk*  : u32 n_recs
 *             u32 n_cols
 *             { u8 col_id; u8 elem_sz; u32 raw_bytes; u32 comp_bytes; } x n_cols
 *             <comp_bytes of zstd frame> x n_cols
 *   trailer : u64 n_chunks, u64 total_recs, "R9TRAILR"    (written on close)
 *
 * The exception column is SPARSE: one entry per faulting/IRQ retire, carrying the
 * record index it applies to, so the common (no-exception) case costs nothing.
 */
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>
#include <zstd.h>

enum ctrace_col : uint8_t {
  CT_PC     = 0,   /* retire pc                        (u64) */
  CT_DST    = 1,   /* architectural dst reg, 0 = none  (u8)  */
  CT_VAL    = 2,   /* retired value                    (u64) */
  CT_FLAGS  = 3,   /* bit0 fp, bit1 fcr, bit2 slot1, bit3 faulted (u8) */
  CT_EXC_IDX= 4,   /* SPARSE: record index of an exception (u32) */
  CT_EXC_CAU= 5,   /* SPARSE: cause                    (u8)  */
  CT_EXC_EPC= 6,   /* SPARSE: epc                      (u64) */
  CT_EXC_BAD= 7,   /* SPARSE: badvaddr                 (u64) */
  /* SPARSE STORE STREAM.  The retire record carries pc/dst/val but no ADDRESS, so a trace
   * alone cannot answer "which instruction wrote this line" -- which is precisely what a
   * memory-corruption symptom (a zeroed inode at a known address) asks.  These three
   * columns log every committed store; they are their own stream and need no alignment
   * against the retire index, so a control-flow fork cannot desync them. */
  CT_ST_PC  = 8,   /* SPARSE: storing instruction pc   (u64) */
  CT_ST_ADDR= 9,   /* SPARSE: store physical address   (u64) */
  CT_ST_DATA=10,   /* SPARSE: store data               (u64) */
};

/* flag bits for CT_FLAGS */
#define CTF_FP      0x1u
#define CTF_FCR     0x2u
#define CTF_SLOT1   0x4u
#define CTF_FAULTED 0x8u

class ctrace_writer {
public:
  ctrace_writer(const char *path, uint32_t chunk_recs, int level, const char *rawpath = nullptr)
    : chunk_recs(chunk_recs), level(level) {
    /* CTRACE_RAW: write the same records uncompressed (pc,val,dst,flags packed) so the
     * reader can be verified BYTE-EXACT against the writer instead of merely self-consistent. */
    if(rawpath) { raw = fopen(rawpath, "wb"); }
    fp = fopen(path, "wb");
    if(fp) {
      fwrite("R9TRACE1", 1, 8, fp);
      cbuf.resize(ZSTD_compressBound(chunk_recs * sizeof(uint64_t)) + 4096);
    }
  }
  ~ctrace_writer() { close(); }
  bool ok() const { return fp != nullptr; }

  void add(uint64_t pc, uint8_t dst, uint64_t val, uint8_t flags) {
    if(!fp) { return; }
    c_pc.push_back(pc); c_dst.push_back(dst); c_val.push_back(val); c_flags.push_back(flags);
    if(raw) { fwrite(&pc,8,1,raw); fwrite(&val,8,1,raw); fwrite(&dst,1,1,raw); fwrite(&flags,1,1,raw); }
    if(c_pc.size() >= chunk_recs) { flush_chunk(); }
  }
  /* sparse: a committed store (pc, physical address, data) -- independent stream */
  void add_store(uint64_t pc, uint64_t addr, uint64_t data) {
    if(!fp) { return; }
    c_stpc.push_back(pc); c_staddr.push_back(addr); c_stdata.push_back(data);
  }
  /* sparse: attach an exception to the record that is about to be / was just added */
  void add_exception(uint8_t cause, uint64_t epc, uint64_t badv) {
    if(!fp) { return; }
    c_eidx.push_back((uint32_t)c_pc.size());
    c_ecau.push_back(cause); c_eepc.push_back(epc); c_ebad.push_back(badv);
  }
  void close() {
    if(!fp) { return; }
    if(!c_pc.empty()) { flush_chunk(); }
    fwrite(&n_chunks, 8, 1, fp);
    fwrite(&total_recs, 8, 1, fp);
    fwrite("R9TRAILR", 1, 8, fp);
    fclose(fp); fp = nullptr;
    if(raw) { fclose(raw); raw = nullptr; }
  }
  uint64_t records() const { return total_recs; }
  uint64_t bytes_out() const { return out_bytes; }

private:
  template <typename T>
  void put_col(uint8_t id, std::vector<T> &v, std::vector<uint8_t> &hdr, std::vector<uint8_t> &body) {
    if(v.empty()) { return; }
    size_t raw = v.size() * sizeof(T);
    if(cbuf.size() < ZSTD_compressBound(raw)) { cbuf.resize(ZSTD_compressBound(raw)); }
    size_t cs = ZSTD_compress(cbuf.data(), cbuf.size(), v.data(), raw, level);
    if(ZSTD_isError(cs)) { return; }
    uint8_t e = (uint8_t)sizeof(T);
    uint32_t r32 = (uint32_t)raw, c32 = (uint32_t)cs;
    hdr.push_back(id); hdr.push_back(e);
    hdr.insert(hdr.end(), (uint8_t*)&r32, (uint8_t*)&r32 + 4);
    hdr.insert(hdr.end(), (uint8_t*)&c32, (uint8_t*)&c32 + 4);
    body.insert(body.end(), cbuf.data(), cbuf.data() + cs);
    ncols_staged++;
  }

  void flush_chunk() {
    std::vector<uint8_t> hdr, body;
    ncols_staged = 0;
    put_col(CT_PC,     c_pc,    hdr, body);
    put_col(CT_DST,    c_dst,   hdr, body);
    put_col(CT_VAL,    c_val,   hdr, body);
    put_col(CT_FLAGS,  c_flags, hdr, body);
    put_col(CT_EXC_IDX,c_eidx,  hdr, body);
    put_col(CT_EXC_CAU,c_ecau,  hdr, body);
    put_col(CT_EXC_EPC,c_eepc,  hdr, body);
    put_col(CT_EXC_BAD,c_ebad,  hdr, body);
    put_col(CT_ST_PC,  c_stpc,  hdr, body);
    put_col(CT_ST_ADDR,c_staddr,hdr, body);
    put_col(CT_ST_DATA,c_stdata,hdr, body);
    uint32_t n = (uint32_t)c_pc.size(), nc = ncols_staged;
    fwrite(&n, 4, 1, fp); fwrite(&nc, 4, 1, fp);
    fwrite(hdr.data(), 1, hdr.size(), fp);
    fwrite(body.data(), 1, body.size(), fp);
    out_bytes += 8 + hdr.size() + body.size();
    total_recs += n; n_chunks++;
    c_pc.clear(); c_dst.clear(); c_val.clear(); c_flags.clear();
    c_eidx.clear(); c_ecau.clear(); c_eepc.clear(); c_ebad.clear();
    c_stpc.clear(); c_staddr.clear(); c_stdata.clear();
  }

  FILE *fp = nullptr;
  FILE *raw = nullptr;
  uint32_t chunk_recs;
  int level;
  uint32_t ncols_staged = 0;
  uint64_t n_chunks = 0, total_recs = 0, out_bytes = 0;
  std::vector<uint64_t> c_pc, c_val, c_eepc, c_ebad, c_stpc, c_staddr, c_stdata;
  std::vector<uint8_t>  c_dst, c_flags, c_ecau;
  std::vector<uint32_t> c_eidx;
  std::vector<char>     cbuf;
};

#endif
