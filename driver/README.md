# ARM (PS) SCSI disk service — henry FPGA

The on-board twin of the Verilator SCSI model. The Zynq PS (the `axilite-mips`
driver) plays the "disk media + DMA back-end" role: it polls the `scsi_shim`
doorbell over AXI-lite, walks the HPC3 `{BP,BC,DP}` descriptor chain in the
shared-DRAM mmap, and does the disk I/O straight into the guest's buffers — the
**same contract validated in sim** (`sim/scsi_service.h`, `sim/henry_scsi.h`,
`sim/henry_tb.cpp`). The per-beat RTL engine is retired; the fabric only raises
the doorbell and completes on the PS's reply.

## Files to copy to the board (`~/axilite-mips/`)
- `driver/scsi_arm.h`     (here)
- `sim/scsi_service.h`    — `scsi_disk`, `scsi_move`, `scsi_service_run`
- `sim/henry_scsi.h`      — the `scsi_req_t`/`scsi_rsp_t` contract + constants

## Integrate into `axi.cc`
```cpp
#include "scsi_arm.h"
// once, after the Driver + DRAM mmap are up and the core is running:
static scsi_disk g_disk;  g_disk.open_image("irix65.img");
d->write32(SCSI_W_SELDELAY, 0);          // 0 => shim default (8192); tune live, no re-synth
// each iteration of the main poll loop:
scsi_arm_poll(d, &g_disk, d->get_vaddr());
```

## AXI register map (matches `ip_hdl/axi_is_the_worst_v1_0_S00_AXI.v`)
| dir | port | meaning |
|-----|------|---------|
| R | 0x30 | `req_seq` doorbell (poll) |
| R | 0x31–0x33 | CDB[0..11] (little-endian words) |
| R | 0x34 | `nbdp` (descriptor head, guest phys) |
| R | 0x35 | `{to_device[16], lun[15:8], dest[7:0]}` |
| W | 0x0D | `rsp_seq` (echo doorbell — write LAST) |
| W | 0x0F | `rsp_residual` (0 on success) |
| W | 0x10 | `{tgt_status[15:8], scsi_status[7:0]}` |
| W | 0x11 | `sel_delay` (shim select→data delay; 0 = default) |

These reads repurpose the old L1D/L2 cache-stat read slots — those counters are
no longer in the AXI read map.

## Notes / caveats
- **Coherence:** the PS reads the request *after* the doorbell, so the guest's
  descriptor/buffer cache-writebacks have drained (the ARM poll latency is the
  real-HW analog of `henry_tb`'s `SVC_DELAY`). After depositing data we issue a
  full barrier, then echo the doorbell last; IRIX's pre-DMA `dma_cache_inv` (+
  the committed L2 dirty-bit fix) keeps the CPU side correct. `/dev/mem` is
  mmap'd `O_SYNC` (uncached), so the barrier is sufficient.
- **Writes** currently land in `scsi_disk`'s in-RAM COW overlay (lost on
  restart). For a persistent root disk, switch `scsi_disk` to `O_RDWR` + `pwrite`.
- The FPGA DRAM address fold (`scsi_fpga_map`) **must** stay in sync with
  `henry_tb`'s `fpga_map` and the M00_AXI map.
