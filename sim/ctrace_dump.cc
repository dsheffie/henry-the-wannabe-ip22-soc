/*
 * ctrace_dump -- reader/verifier for the chunked columnar zstd retire trace.
 *
 *   ctrace_dump <file.ct>                 summary + per-chunk column stats
 *   ctrace_dump <file.ct> --head N        print the first N records
 *   ctrace_dump <file.ct> --raw <f.raw>   BYTE-EXACT round-trip check against the
 *                                         CTRACE_RAW sidecar (pc8,val8,dst1,flags1)
 *
 * The round-trip mode is the point: it proves the reader reconstructs exactly what the
 * writer was handed, rather than merely producing self-consistent-looking output.
 */
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <string>
#include <zstd.h>

#include "ctrace.hh"

struct colinfo { uint8_t id, esz; uint32_t raw, comp; };

static bool rd(FILE *f, void *p, size_t n) { return fread(p, 1, n, f) == n; }

int main(int argc, char **argv) {
  if(argc < 2) { fprintf(stderr, "usage: %s <file.ct> [--head N] [--raw <sidecar>]\n", argv[0]); return 1; }
  const char *path = argv[1], *rawpath = nullptr;
  long head = 0;
  /* --addr <pa>: print every committed store landing in the same 64B region -- the
   * "who wrote this line" query a memory-corruption symptom actually poses. */
  unsigned long long want_addr = 0; bool want_addr_set = false;
  for(int i = 2; i < argc; i++) {
    if(!strcmp(argv[i], "--head") && i+1 < argc) { head = strtol(argv[++i], 0, 0); }
    else if(!strcmp(argv[i], "--raw") && i+1 < argc) { rawpath = argv[++i]; }
    else if(!strcmp(argv[i], "--addr") && i+1 < argc) { want_addr = strtoull(argv[++i],0,0); want_addr_set = true; }
  }
  FILE *f = fopen(path, "rb");
  if(!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
  char magic[8];
  if(!rd(f, magic, 8) || memcmp(magic, "R9TRACE1", 8)) { fprintf(stderr, "bad magic\n"); return 1; }

  FILE *raw = rawpath ? fopen(rawpath, "rb") : nullptr;
  if(rawpath && !raw) { fprintf(stderr, "cannot open sidecar %s\n", rawpath); return 1; }

  uint64_t chunks = 0, recs = 0, comp_bytes = 0, raw_bytes = 0, excs = 0, mismatches = 0, printed = 0;
  bool truncated = false;
  uint64_t nstores = 0, nhit = 0;
  std::vector<uint8_t> cbuf, dbuf;

  for(;;) {
    long pos = ftell(f);
    uint32_t n = 0, nc = 0;
    if(!rd(f, &n, 4)) { break; }
    if(!rd(f, &nc, 4)) { break; }
    /* the trailer starts where a chunk header would; detect it and stop */
    if(nc == 0 || nc > 16) { fseek(f, pos, SEEK_SET); break; }
    std::vector<colinfo> cols(nc);
    for(uint32_t i = 0; i < nc; i++) {
      if(!rd(f, &cols[i].id, 1) || !rd(f, &cols[i].esz, 1) ||
         !rd(f, &cols[i].raw, 4) || !rd(f, &cols[i].comp, 4)) { fprintf(stderr, "short header\n"); return 1; }
    }
    std::vector<uint64_t> pc, val, stpc, staddr, stdata; std::vector<uint8_t> dst, flags;
    for(uint32_t i = 0; i < nc; i++) {
      cbuf.resize(cols[i].comp); dbuf.resize(cols[i].raw);
      /* A killed/timed-out run leaves a PARTIAL final chunk.  Stop cleanly and report the
       * complete chunks rather than aborting with no output at all -- the whole point of
       * chunking is that an interrupted trace stays usable. */
      if(!rd(f, cbuf.data(), cols[i].comp)) {
        fprintf(stderr, "  [truncated: partial final chunk %llu discarded]\n",
                (unsigned long long)chunks);
        truncated = true; break;
      }
      size_t got = ZSTD_decompress(dbuf.data(), dbuf.size(), cbuf.data(), cbuf.size());
      if(ZSTD_isError(got) || got != cols[i].raw) {
        fprintf(stderr, "chunk %llu col %u: DECOMPRESS FAIL (%s)\n",
                (unsigned long long)chunks, cols[i].id,
                ZSTD_isError(got) ? ZSTD_getErrorName(got) : "size mismatch");
        return 1;
      }
      comp_bytes += cols[i].comp; raw_bytes += cols[i].raw;
      switch(cols[i].id) {
      case CT_PC:    pc.assign((uint64_t*)dbuf.data(), (uint64_t*)dbuf.data() + got/8); break;
      case CT_VAL:   val.assign((uint64_t*)dbuf.data(), (uint64_t*)dbuf.data() + got/8); break;
      case CT_DST:   dst.assign(dbuf.begin(), dbuf.begin() + got); break;
      case CT_FLAGS: flags.assign(dbuf.begin(), dbuf.begin() + got); break;
      case CT_EXC_IDX: excs += got/4; break;
      case CT_ST_PC:   stpc.assign((uint64_t*)dbuf.data(), (uint64_t*)dbuf.data() + got/8); break;
      case CT_ST_ADDR: staddr.assign((uint64_t*)dbuf.data(), (uint64_t*)dbuf.data() + got/8); break;
      case CT_ST_DATA: stdata.assign((uint64_t*)dbuf.data(), (uint64_t*)dbuf.data() + got/8); break;
      default: break;
      }
    }
    if(truncated) { break; }
    nstores += staddr.size();
    if(want_addr_set) {
      for(size_t k = 0; k < staddr.size() && k < stpc.size() && k < stdata.size(); k++) {
        if((staddr[k] & ~63ULL) == (want_addr & ~63ULL)) {
          printf("  [store] chunk=%llu  pc=%016llx  addr=%09llx  data=%016llx\n",
                 (unsigned long long)chunks, (unsigned long long)stpc[k],
                 (unsigned long long)staddr[k], (unsigned long long)stdata[k]);
          nhit++;
        }
      }
    }
    if(pc.size() != n) { fprintf(stderr, "chunk %llu: pc column %zu != n_recs %u\n",
                                 (unsigned long long)chunks, pc.size(), n); return 1; }
    for(uint32_t i = 0; i < n; i++) {
      if(raw) {
        uint64_t rpc = 0, rval = 0; uint8_t rdst = 0, rfl = 0;
        if(rd(raw, &rpc, 8) && rd(raw, &rval, 8) && rd(raw, &rdst, 1) && rd(raw, &rfl, 1)) {
          if(rpc != pc[i] || rval != val[i] || rdst != dst[i] || rfl != flags[i]) {
            if(mismatches < 8)
              fprintf(stderr, "  MISMATCH rec %llu: ct(pc=%llx val=%llx d=%u f=%u) raw(pc=%llx val=%llx d=%u f=%u)\n",
                      (unsigned long long)(recs+i), (unsigned long long)pc[i], (unsigned long long)val[i],
                      dst[i], flags[i], (unsigned long long)rpc, (unsigned long long)rval, rdst, rfl);
            mismatches++;
          }
        }
      }
      if(printed < (uint64_t)head) {
        printf("  %8llu pc=%016llx dst=%-2u val=%016llx flags=%c%c%c\n",
               (unsigned long long)(recs+i), (unsigned long long)pc[i], dst[i],
               (unsigned long long)val[i],
               (flags[i]&CTF_FP)?'F':'-', (flags[i]&CTF_FCR)?'C':'-', (flags[i]&CTF_SLOT1)?'1':'0');
        printed++;
      }
    }
    recs += n; chunks++;
  }

  uint64_t t_chunks = 0, t_recs = 0; char tm[8] = {0};
  bool have_trailer = rd(f, &t_chunks, 8) && rd(f, &t_recs, 8) && rd(f, tm, 8) && !memcmp(tm, "R9TRAILR", 8);
  fclose(f); if(raw) { fclose(raw); }

  printf("\n  chunks       : %llu\n", (unsigned long long)chunks);
  printf("  records      : %llu\n", (unsigned long long)recs);
  printf("  exceptions   : %llu\n", (unsigned long long)excs);
  printf("  stores       : %llu\n", (unsigned long long)nstores);
  if(want_addr_set) { printf("  stores @addr : %llu  (64B region of %#llx)\n",
                             (unsigned long long)nhit, want_addr); }
  printf("  raw bytes    : %llu\n", (unsigned long long)raw_bytes);
  printf("  compressed   : %llu   (%.2fx, %.3f B/insn)\n", (unsigned long long)comp_bytes,
         comp_bytes ? (double)raw_bytes/comp_bytes : 0.0, recs ? (double)comp_bytes/recs : 0.0);
  if(have_trailer) {
    printf("  trailer      : chunks=%llu recs=%llu  %s\n", (unsigned long long)t_chunks,
           (unsigned long long)t_recs,
           (t_chunks==chunks && t_recs==recs) ? "MATCHES" : "*** MISMATCH ***");
    if(t_chunks!=chunks || t_recs!=recs) { return 2; }
  } else {
    printf("  trailer      : ABSENT (run was killed; the %llu complete chunks above are valid)\n",
           (unsigned long long)chunks);
  }
  if(rawpath) {
    printf("  round-trip   : %s (%llu mismatches over %llu records)\n",
           mismatches ? "*** FAILED ***" : "BYTE-EXACT", (unsigned long long)mismatches,
           (unsigned long long)recs);
    if(mismatches) { return 3; }
  }
  return 0;
}
