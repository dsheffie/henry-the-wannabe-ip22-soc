// Standalone unit test for scsi_dma.sv -- exercises the descriptor walk + the
// mem<->disk beat streaming through a model arbiter/DRAM port that mirrors
// henry's byte order (each 32-bit line lane = little-endian bytes from g_mem;
// descriptor words are big-endian, i.e. bswap of the lane).
//
// Cases: READ single-desc, READ chained (DP follow), WRITE single-desc.
#include "Vscsi_dma.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>

static const uint32_t MEMSZ = 1u << 18;          // 256 KB model DRAM
static uint8_t mem[MEMSZ];

// descriptor words are big-endian in DRAM
static void put_be32(uint32_t pa, uint32_t v){ mem[pa]=v>>24; mem[pa+1]=v>>16; mem[pa+2]=v>>8; mem[pa+3]=v; }

// HPC3 BC flags
static const uint32_t BC_XIE = 0x20000000u, BC_EOX = 0x80000000u;

// disk ramp: global byte b -> value (b & 0xff)+0x10 offset to avoid 0 confusion
static inline uint8_t ramp(uint64_t b){ return (uint8_t)(b * 7 + 3); }

int main(int argc, char** argv){
  Verilated::commandArgs(argc, argv);
  Vscsi_dma* d = new Vscsi_dma;

  // ---- model arbiter / DRAM port ----
  // The engine (like dma_memcpy) can hold dma_req_valid high across two distinct
  // requests; the real arbiter inserts the AXI turnaround.  Model that by
  // accepting a NEW request whenever valid is high, no reply is in flight, and
  // (addr,op) differ from the last-accepted (with a 1-cycle gap after a reply).
  long cyc = 0; int64_t reply = -1; int64_t resp_cyc = -100;
  uint32_t req_addr=0, req_op=0, req_mask=0, req_sd[4]={0,0,0,0};
  uint32_t last_addr=0xffffffff, last_op=0xff;
  const int LAT = 4;

  // ---- disk side ----
  uint64_t rd_byte = 0;                 // READ: global ramp cursor (bytes consumed)
  std::vector<uint8_t> wr_capture;      // WRITE: bytes pushed to disk

  d->reset = 1; d->go = 0; d->cancel = 0; d->clk = 0; d->eval();
  for(int i=0;i<4;i++){ d->clk=1; d->eval(); d->clk=0; d->eval(); cyc++; }
  d->reset = 0;

  // returns true once the engine pulses done
  auto run = [&](uint32_t nbdp, int to_dev)->bool{
    last_addr = 0xffffffff; last_op = 0xff; reply = -1;
    d->nbdp = nbdp; d->to_device = to_dev; d->go = 1;
    bool saw_done = false; int guard = 0;
    while(guard++ < 100000){
      // --- mem response for this cycle ---
      d->dma_rsp_valid = 0;
      if(reply == cyc){
        if(req_op == 4){
          for(int i=0;i<4;i++){ uint32_t a=(req_addr+4*i)&(MEMSZ-1);
            d->dma_rsp_load_data[i] = (uint32_t)mem[a] | ((uint32_t)mem[a+1]<<8) |
              ((uint32_t)mem[a+2]<<16) | ((uint32_t)mem[a+3]<<24); }
        } else if(req_op == 7){
          for(int i=0;i<16;i++) if((req_mask>>i)&1){ uint32_t a=(req_addr+i)&(MEMSZ-1);
            mem[a] = (req_sd[i>>2] >> (8*(i&3))) & 0xff; }
        }
        d->dma_rsp_valid = 1; reply = -1; resp_cyc = cyc;
      }
      // --- disk read data (ramp), aligned to the 16-byte beat the engine will latch ---
      for(int i=0;i<4;i++){
        uint32_t w=0; for(int j=0;j<4;j++) w |= (uint32_t)ramp(rd_byte + 4*i + j) << (8*j);
        d->disk_rd_data[i] = w;
      }
      d->disk_rd_valid = 1;   // unit test: a beat is always ready (matches the old assumed-ready behavior)

      d->clk = 0; d->eval();                 // comb settle (engine sees rsp + disk data)
      int rd = d->disk_rd_en, wr = d->disk_wr_en, rv = d->dma_req_valid;
      uint32_t addr = d->dma_req_addr, op = d->dma_req_opcode;
      // accept a new request: valid, nothing in flight, 1-cycle gap after a reply,
      // and a genuinely different (addr,op) than the one we last took.
      if(rv && reply < 0 && cyc > resp_cyc && (addr != last_addr || op != last_op)){
        req_addr = addr; req_op = op; req_mask = d->dma_req_mask;
        for(int i=0;i<4;i++) req_sd[i] = d->dma_req_store_data[i];
        reply = cyc + LAT; last_addr = addr; last_op = op;
      }
      if(wr){ for(int i=0;i<16;i++) wr_capture.push_back((d->disk_wr_data[i>>2] >> (8*(i&3))) & 0xff); }

      d->clk = 1; d->eval();                 // posedge latch
      if(rd) rd_byte += 16;                  // a beat was consumed
      if(d->done) saw_done = true;
      d->go = 0;
      cyc++;
      if(saw_done) return true;
    }
    return false;
  };

  int fails = 0;
  auto check = [&](const char* name, bool ok){ printf("  %s  %s\n", ok?"PASS":"FAIL", name); if(!ok) fails++; };

  // ---- Case 1: READ single descriptor, 64 bytes (4 beats) ----
  memset(mem, 0, sizeof(mem)); rd_byte = 0; wr_capture.clear();
  put_be32(0x1000, 0x2000);                 // BP
  put_be32(0x1004, 64 | BC_EOX);            // BC = 64, EOX
  put_be32(0x1008, 0);                      // DP (unused)
  bool done1 = run(0x1000, 0);
  bool ok1 = done1;
  for(uint32_t k=0;k<64;k++) if(mem[0x2000+k] != ramp(k)) ok1 = false;
  check("READ single-desc 64B -> mem matches disk ramp", ok1);

  // ---- Case 2: READ chained: desc0 32B @0x2000, desc1 32B @0x3000 ----
  memset(mem, 0, sizeof(mem)); rd_byte = 0; wr_capture.clear();
  put_be32(0x1000, 0x2000); put_be32(0x1004, 32);            put_be32(0x1008, 0x1010);
  put_be32(0x1010, 0x3000); put_be32(0x1014, 32 | BC_EOX);   put_be32(0x1018, 0);
  bool done2 = run(0x1000, 0);
  bool ok2 = done2;
  for(uint32_t k=0;k<32;k++) if(mem[0x2000+k] != ramp(k))      ok2 = false;
  for(uint32_t k=0;k<32;k++) if(mem[0x3000+k] != ramp(32+k))   ok2 = false;  // ramp continues across descs
  check("READ chained 32B+32B -> both buffers, ramp continuous", ok2);

  // ---- Case 3: WRITE single descriptor, 48 bytes (3 beats), mem -> disk ----
  memset(mem, 0, sizeof(mem)); rd_byte = 0; wr_capture.clear();
  for(uint32_t k=0;k<48;k++) mem[0x4000+k] = ramp(k);
  put_be32(0x1000, 0x4000); put_be32(0x1004, 48 | BC_XIE | BC_EOX); put_be32(0x1008, 0);
  bool done3 = run(0x1000, 1);
  bool ok3 = done3 && wr_capture.size()==48;
  for(uint32_t k=0;k<48 && k<wr_capture.size();k++) if(wr_capture[k] != ramp(k)) ok3 = false;
  check("WRITE single-desc 48B -> disk capture matches mem", ok3);

  printf("== scsi_dma unit test: %s ==\n", fails? "FAIL":"PASS");
  delete d;
  return fails ? 1 : 0;
}
