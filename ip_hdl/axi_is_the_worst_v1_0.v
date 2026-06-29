
`timescale 1 ns / 1 ps


module axi_is_the_worst_v1_0 #
  (
   // Users to add parameters here

   // User parameters ends
   // Do not modify the parameters beyond this line


   // Parameters of Axi Slave Bus Interface S00_AXI
   parameter integer C_S00_AXI_DATA_WIDTH = 32,
   parameter integer C_S00_AXI_ADDR_WIDTH = 8, 
		     
   // Parameters of Axi Master Bus Interface M00_AXI
   parameter C_M00_AXI_TARGET_SLAVE_BASE_ADDR = 32'h40000000,
   parameter integer C_M00_AXI_BURST_LEN = 1,
   parameter integer C_M00_AXI_ID_WIDTH = 1,
   parameter integer C_M00_AXI_ADDR_WIDTH = 32,
   parameter integer C_M00_AXI_DATA_WIDTH = 128,
   parameter integer C_M00_AXI_AWUSER_WIDTH = 0,
   parameter integer C_M00_AXI_ARUSER_WIDTH = 0,
   parameter integer C_M00_AXI_WUSER_WIDTH = 0,
   parameter integer C_M00_AXI_RUSER_WIDTH = 0,
   parameter integer C_M00_AXI_BUSER_WIDTH = 0
   )
   (
    // Users to add ports here

    // User ports ends
    // Do not modify the ports beyond this line


    // Ports of Axi Slave Bus Interface S00_AXI
    input wire 					s00_axi_aclk,
    input wire 					s00_axi_aresetn,
    input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] 	s00_axi_awaddr,
    input wire [2 : 0] 				s00_axi_awprot,
    input wire 					s00_axi_awvalid,
    output wire 				s00_axi_awready,
    input wire [C_S00_AXI_DATA_WIDTH-1 : 0] 	s00_axi_wdata,
    input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
    input wire 					s00_axi_wvalid,
    output wire 				s00_axi_wready,
    output wire [1 : 0] 			s00_axi_bresp,
    output wire 				s00_axi_bvalid,
    input wire 					s00_axi_bready,
    input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] 	s00_axi_araddr,
    input wire [2 : 0] 				s00_axi_arprot,
    input wire 					s00_axi_arvalid,
    output wire 				s00_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1 : 0] 	s00_axi_rdata,
    output wire [1 : 0] 			s00_axi_rresp,
    output wire 				s00_axi_rvalid,
    input wire 					s00_axi_rready,

    // Ports of Axi Master Bus Interface M00_AXI
    input wire 					m00_axi_init_axi_txn,
    output wire 				m00_axi_txn_done,
    output wire 				m00_axi_error,
    input wire 					m00_axi_aclk,
    input wire 					m00_axi_aresetn,
    output wire [C_M00_AXI_ID_WIDTH-1 : 0] 	m00_axi_awid,
    output wire [C_M00_AXI_ADDR_WIDTH-1 : 0] 	m00_axi_awaddr,
    output wire [7 : 0] 			m00_axi_awlen,
    output wire [2 : 0] 			m00_axi_awsize,
    output wire [1 : 0] 			m00_axi_awburst,
    output wire 				m00_axi_awlock,
    output wire [3 : 0] 			m00_axi_awcache,
    output wire [2 : 0] 			m00_axi_awprot,
    output wire [3 : 0] 			m00_axi_awqos,
    output wire [C_M00_AXI_AWUSER_WIDTH-1 : 0] 	m00_axi_awuser,
    output wire 				m00_axi_awvalid,
    input wire 					m00_axi_awready,
    output wire [C_M00_AXI_DATA_WIDTH-1 : 0] 	m00_axi_wdata,
    output wire [C_M00_AXI_DATA_WIDTH/8-1 : 0] 	m00_axi_wstrb,
    output wire 				m00_axi_wlast,
    output wire [C_M00_AXI_WUSER_WIDTH-1 : 0] 	m00_axi_wuser,
    output wire 				m00_axi_wvalid,
    input wire 					m00_axi_wready,
    input wire [C_M00_AXI_ID_WIDTH-1 : 0] 	m00_axi_bid,
    input wire [1 : 0] 				m00_axi_bresp,
    input wire [C_M00_AXI_BUSER_WIDTH-1 : 0] 	m00_axi_buser,
    input wire 					m00_axi_bvalid,
    output wire 				m00_axi_bready,
    output wire [C_M00_AXI_ID_WIDTH-1 : 0] 	m00_axi_arid,
    output wire [C_M00_AXI_ADDR_WIDTH-1 : 0] 	m00_axi_araddr,
    output wire [7 : 0] 			m00_axi_arlen,
    output wire [2 : 0] 			m00_axi_arsize,
    output wire [1 : 0] 			m00_axi_arburst,
    output wire 				m00_axi_arlock,
    output wire [3 : 0] 			m00_axi_arcache,
    output wire [2 : 0] 			m00_axi_arprot,
    output wire [3 : 0] 			m00_axi_arqos,
    output wire [C_M00_AXI_ARUSER_WIDTH-1 : 0] 	m00_axi_aruser,
    output wire 				m00_axi_arvalid,
    input wire 					m00_axi_arready,
    input wire [C_M00_AXI_ID_WIDTH-1 : 0] 	m00_axi_rid,
    input wire [C_M00_AXI_DATA_WIDTH-1 : 0] 	m00_axi_rdata,
    input wire [1 : 0] 				m00_axi_rresp,
    input wire 					m00_axi_rlast,
    input wire [C_M00_AXI_RUSER_WIDTH-1 : 0] 	m00_axi_ruser,
    input wire 					m00_axi_rvalid,
    output wire 				m00_axi_rready
    );
   wire [31:0] 					w_controlreg,w_baseaddr,w_status;
   wire [31:0]					w_addrmask;
   
   wire [31:0] 					w_mem_req_addr;
   wire [31:0] 					w_axi_addr = w_baseaddr+(w_mem_req_addr);

   wire [127:0]					w_mem_req_store_data;
   wire						w_axi_busy;
   
   
   //outputs to axi slave
   wire [31:0] 					w_rvcontrol, w_resume_pc;

   //inputs to axi slave
   wire [31:0] 					w_rvstatus, w_epc, w_badvaddr;
   wire [31:0]					w_states;
   wire [4:0]					w_cause;
   wire [11:0]					w_trace_index;
   wire [31:0]					w_trace_data;
   wire [8:0]					w_trace_wptr;
   wire						w_l1i_flush_done, w_l1d_flush_done, w_l2_flush_done;
   
   

   wire [31:0] 					w_pc, w_pc2;
   wire [6:0]					w_op, w_op2;
   
   wire 					w_pc_valid, w_pc2_valid;
   
   wire 					w_reset_out, 
						w_in_flush,
						w_ready, 
						w_got_break,
						w_got_ud,
						w_got_bad_addr;

   wire [4:0]					w_state; //5
   wire [3:0]					w_dstate, w_l2state,  w_axistate, w_l2rsp_state; //12
   wire [2:0]					w_istate; //3
   

   wire [63:0] 					w_l1i_cache_accesses = 'd0;
   wire [63:0] 					w_l1i_cache_hits = 'd0;
   wire [63:0] 					w_l1d_cache_accesses = 'd0;
   wire [63:0] 					w_l1d_cache_hits = 'd0;
   wire [63:0] 					w_l2_cache_accesses = 'd0;
   wire [63:0] 					w_l2_cache_hits = 'd0;
   wire [63:0]					w_l2_early_accesses = 'd0;
   

   wire [63:0]					w_axi_writes;
   wire [63:0]					w_axi_reads;   
   
   
   wire [63:0]					w_txn_lat, w_txn_cnt;
   wire 					w_reset = (s00_axi_aresetn==1'b0);
   
   
   //connects to axi master
   wire 					w_mem_req_valid, w_mem_rsp_valid;
   wire						w_mem_rsp_bad;
   
   wire [15:0]					w_mem_req_mask;
   
   wire						w_mem_req_gnt;
   wire [1:0]					w_mem_req_tag, w_mem_rsp_tag;

   assign w_mem_req_tag = 2'd0;
   
   
   wire [4:0]					w_mem_req_opcode;
   wire [127:0]					w_load_data;
   
   wire						w_memq_empty;
   wire [5:0]					w_inflight;

   wire [4:0]					w_reg_ptr0, w_reg_ptr1;
   wire [31:0]					w_reg_data0, w_reg_data1;
   wire						w_reg_val0, w_reg_val1;
   
   
   wire 					w_putchar_fifo_empty;
   wire [7:0]					w_putchar_fifo_out;
   wire 					w_putchar_fifo_pop;
   wire [3:0]					w_putchar_fifo_rptr, w_putchar_fifo_wptr;

   // SCC serial Rx: ARM/PS -> S00_AXI -> core Rx FIFO
   wire 					w_scc_rx_push;
   wire [7:0]					w_scc_rx_data;
   wire 					w_scc_rx_full;
   
   assign w_states = {
		      2'd0,
		      w_l2rsp_state,
		      w_inflight,
		      w_axistate, //16
		      w_dstate, //12
		      w_istate, //9
		      w_l2state, //5
		      w_state //0
		      };

   
   assign w_rvstatus = {w_memq_empty,
			2'd0,
			w_istate[2:0],
			w_mem_rsp_valid, 
			w_dstate, //4 bits
			w_mem_req_opcode[3:0], //4 bits
			w_mem_req_valid,
			w_reset_out,
			w_l2state,
			w_state,//6
			1'b0, //5
			w_got_bad_addr, //4
			w_got_ud, //3
			w_got_break, //2
			w_in_flush, //1
			w_ready}; //0

   wire [31:0]					w_last_addr, w_last_data;
   wire [31:0]					w_max_fetches;


   wire [31:0]					w_branch_pc;
   wire						w_branch_val, w_branch_fault;

   wire						w_sgi_mode;
   wire [31:0]					w_status_reg;
   

   
   // ---- SCSI mailbox wires: henry_soc publishes req_*, S00_AXI returns rsp_*/sel_delay ----
   wire [31:0]  w_scsi_req_seq, w_scsi_req_nbdp, w_scsi_rsp_seq, w_scsi_rsp_residual;
   wire [127:0] w_scsi_req_cdb;
   wire [7:0]   w_scsi_req_dest, w_scsi_req_lun, w_scsi_rsp_scsi_status, w_scsi_rsp_tgt_status;
   wire         w_scsi_req_to_device;
   wire [15:0]  w_scsi_sel_delay;
   axi_is_the_worst_v1_0_S00_AXI # ( .C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH), .C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)) 
   axi_is_the_worst_v1_0_S00_AXI_inst (
				       .controlreg(w_controlreg),
				       .base(w_baseaddr),
				       .mask(w_addrmask),
				       .status(w_status),
				       .last_addr(w_last_addr),
				       .last_data(w_last_data),				       
				       .putchar_fifo_out(w_putchar_fifo_out),
				       .putchar_fifo_empty(w_putchar_fifo_empty),
				       .putchar_fifo_pop(w_putchar_fifo_pop),
				       .putchar_fifo_wptr(w_putchar_fifo_wptr),
				       .putchar_fifo_rptr(w_putchar_fifo_rptr),
				       .scc_rx_push(w_scc_rx_push),
				       .scc_rx_data(w_scc_rx_data),
				       .scc_rx_full(w_scc_rx_full),
				       .control(w_rvcontrol),
				       .resume_pc(w_resume_pc),
				       .rvstatus(w_rvstatus),
				       .states(w_states),
				       .sgi_mode(w_sgi_mode),				       
				       .epc(w_epc),
				       .status_reg(w_status_reg),
				       .badvaddr(w_badvaddr),
				       .cause(w_cause),
				       .dbg_trace_data(w_trace_data),
				       .dbg_trace_wptr(w_trace_wptr),
				       .dbg_trace_index(w_trace_index),
				       .l1i_flush_done(w_l1i_flush_done),
				       .l1d_flush_done(w_l1d_flush_done),
				       .l2_flush_done(w_l2_flush_done),				       
				       .rv_mem_addr(w_axi_addr),
				       .pc(w_pc),
				       .pc2(w_pc2),
				       .pc_valid(w_pc_valid),
				       .pc2_valid(w_pc2_valid),
				       .op(w_op),
				       .op2(w_op2),
				       
				       .branch_pc(w_branch_pc),
				       .branch_pc_valid(w_branch_val),
				       .branch_fault(w_branch_fault),

				       .mem_rsp_valid(w_mem_rsp_valid),
				       .mem_rsp_load_data(w_load_data),
				       .mem_req_addr(w_mem_req_addr),
				       .mem_req_valid(w_mem_req_valid),				       
				       
				       .retire_reg_ptr(w_reg_ptr0),
				       .retire_reg_data(w_reg_data0),
				       .retire_reg_valid(w_reg_val0),
				       .retire_reg_two_ptr(w_reg_ptr1),
				       .retire_reg_two_data(w_reg_data1),
				       .retire_reg_two_valid(w_reg_val1),

				       
				       .l1i_cache_accesses(w_l1i_cache_accesses),
				       .l1i_cache_hits(w_l1i_cache_hits),
				       .l1d_cache_accesses(w_l1d_cache_accesses),
				       .l1d_cache_hits(w_l1d_cache_hits),
				       .l2_cache_accesses(w_l2_cache_accesses),
				       .l2_cache_hits(w_l2_cache_hits),
				       /*.l2_early_accesses(w_l2_early_accesses), */
				       .branch_faults('d0),
				       .axi_busy(w_axi_busy),				       
				       .dram_req_cnt(w_txn_cnt),
				       .dram_req_cycles(w_txn_lat),
				       .axi_reads(w_axi_reads),
				       .axi_writes(w_axi_writes),
				       .max_fetches(w_max_fetches),
				       .rv_reset(w_rvcontrol[0]),

				       .scsi_req_seq(w_scsi_req_seq),
				       .scsi_req_cdb(w_scsi_req_cdb),
				       .scsi_req_nbdp(w_scsi_req_nbdp),
				       .scsi_req_dest(w_scsi_req_dest),
				       .scsi_req_lun(w_scsi_req_lun),
				       .scsi_req_to_device(w_scsi_req_to_device),
				       .scsi_rsp_seq(w_scsi_rsp_seq),
				       .scsi_rsp_residual(w_scsi_rsp_residual),
				       .scsi_rsp_scsi_status(w_scsi_rsp_scsi_status),
				       .scsi_rsp_tgt_status(w_scsi_rsp_tgt_status),
				       .scsi_sel_delay(w_scsi_sel_delay),
				       .S_AXI_ACLK(s00_axi_aclk),
				       .S_AXI_ARESETN(s00_axi_aresetn),
				       .S_AXI_AWADDR(s00_axi_awaddr),
				       .S_AXI_AWPROT(s00_axi_awprot),
				       .S_AXI_AWVALID(s00_axi_awvalid),
				       .S_AXI_AWREADY(s00_axi_awready),
				       .S_AXI_WDATA(s00_axi_wdata),
				       .S_AXI_WSTRB(s00_axi_wstrb),
				       .S_AXI_WVALID(s00_axi_wvalid),
				       .S_AXI_WREADY(s00_axi_wready),
				       .S_AXI_BRESP(s00_axi_bresp),
				       .S_AXI_BVALID(s00_axi_bvalid),
				       .S_AXI_BREADY(s00_axi_bready),
				       .S_AXI_ARADDR(s00_axi_araddr),
				       .S_AXI_ARPROT(s00_axi_arprot),
				       .S_AXI_ARVALID(s00_axi_arvalid),
				       .S_AXI_ARREADY(s00_axi_arready),
				       .S_AXI_RDATA(s00_axi_rdata),
				       .S_AXI_RRESP(s00_axi_rresp),
				       .S_AXI_RVALID(s00_axi_rvalid),
				       .S_AXI_RREADY(s00_axi_rready)
				       );

   // Instantiation of Axi Bus Interface M00_AXI

   
   axi_is_the_worst_v1_0_M00_AXI # ( 
				     .C_M_TARGET_SLAVE_BASE_ADDR(0), 
				     .C_M_AXI_BURST_LEN(C_M00_AXI_BURST_LEN),
				     .C_M_AXI_ID_WIDTH(C_M00_AXI_ID_WIDTH), 
				     .C_M_AXI_ADDR_WIDTH(C_M00_AXI_ADDR_WIDTH),
				     .C_M_AXI_DATA_WIDTH(C_M00_AXI_DATA_WIDTH),
				     .C_M_AXI_AWUSER_WIDTH(C_M00_AXI_AWUSER_WIDTH),
				     .C_M_AXI_ARUSER_WIDTH(C_M00_AXI_ARUSER_WIDTH),
				     .C_M_AXI_WUSER_WIDTH(C_M00_AXI_WUSER_WIDTH),
				     .C_M_AXI_RUSER_WIDTH(C_M00_AXI_RUSER_WIDTH),
				     .C_M_AXI_BUSER_WIDTH(C_M00_AXI_BUSER_WIDTH)
				     )
   axi_is_the_worst_v1_0_M00_AXI_inst (
				       .rv_reset(w_rvcontrol[0]),
				       .step_txn(w_rvcontrol[16]),
				       .ack_txn(1'b0),
				       .baseaddr(w_baseaddr),
				       .addrmask(w_addrmask),
				       .cpuaddr(w_mem_req_addr),
				       .txn_lat(w_txn_lat),
				       .txn_cnt(w_txn_cnt),
				       .load_data(w_load_data),
				       .axi_busy(w_axi_busy),
				       .state(w_axistate),
				       .last_addr(w_last_addr),
				       .last_data(w_last_data),
				       .axi_reads(w_axi_reads),
				       .axi_writes(w_axi_writes),
				       .max_fetches(w_max_fetches),		
				       .sgi_mode(w_sgi_mode),
				       .mem_req_store_data(w_mem_req_store_data),
				       
				       .mem_req_valid(w_mem_req_valid),
				       .mem_req_tag(w_mem_req_tag),
				       .mem_opcode(w_mem_req_opcode),
				       .mem_mask(w_mem_req_mask),
				       .mem_rsp_valid(w_mem_rsp_valid),
				       .mem_rsp_bad(w_mem_rsp_bad),				       				       
				       .mem_rsp_tag(w_mem_rsp_tag),				       
				       .mem_req_gnt(w_mem_req_gnt),
				       .INIT_AXI_TXN(m00_axi_init_axi_txn),
				       .TXN_DONE(m00_axi_txn_done),
				       .ERROR(m00_axi_error),
				       .M_AXI_ACLK(m00_axi_aclk),
				       .M_AXI_ARESETN(m00_axi_aresetn),
				       .M_AXI_AWID(m00_axi_awid),
				       .M_AXI_AWADDR(m00_axi_awaddr),
				       .M_AXI_AWLEN(m00_axi_awlen),
				       .M_AXI_AWSIZE(m00_axi_awsize),
				       .M_AXI_AWBURST(m00_axi_awburst),
				       .M_AXI_AWLOCK(m00_axi_awlock),
				       .M_AXI_AWCACHE(m00_axi_awcache),
				       .M_AXI_AWPROT(m00_axi_awprot),
				       .M_AXI_AWQOS(m00_axi_awqos),
				       .M_AXI_AWUSER(m00_axi_awuser),
				       .M_AXI_AWVALID(m00_axi_awvalid),
				       .M_AXI_AWREADY(m00_axi_awready),
				       .M_AXI_WDATA(m00_axi_wdata),
				       .M_AXI_WSTRB(m00_axi_wstrb),
				       .M_AXI_WLAST(m00_axi_wlast),
				       .M_AXI_WUSER(m00_axi_wuser),
				       .M_AXI_WVALID(m00_axi_wvalid),
				       .M_AXI_WREADY(m00_axi_wready),
				       .M_AXI_BID(m00_axi_bid),
				       .M_AXI_BRESP(m00_axi_bresp),
				       .M_AXI_BUSER(m00_axi_buser),
				       .M_AXI_BVALID(m00_axi_bvalid),
				       .M_AXI_BREADY(m00_axi_bready),
				       .M_AXI_ARID(m00_axi_arid),
				       .M_AXI_ARADDR(m00_axi_araddr),
				       .M_AXI_ARLEN(m00_axi_arlen),
				       .M_AXI_ARSIZE(m00_axi_arsize),
				       .M_AXI_ARBURST(m00_axi_arburst),
				       .M_AXI_ARLOCK(m00_axi_arlock),
				       .M_AXI_ARCACHE(m00_axi_arcache),
				       .M_AXI_ARPROT(m00_axi_arprot),
				       .M_AXI_ARQOS(m00_axi_arqos),
				       .M_AXI_ARUSER(m00_axi_aruser),
				       .M_AXI_ARVALID(m00_axi_arvalid),
				       .M_AXI_ARREADY(m00_axi_arready),
				       .M_AXI_RID(m00_axi_rid),
				       .M_AXI_RDATA(m00_axi_rdata),
				       .M_AXI_RRESP(m00_axi_rresp),
				       .M_AXI_RLAST(m00_axi_rlast),
				       .M_AXI_RUSER(m00_axi_ruser),
				       .M_AXI_RVALID(m00_axi_rvalid),
				       .M_AXI_RREADY(m00_axi_rready)
				       );

   // Add user logic here


   wire [63:0]					w_resume_pc64 = { {32{w_resume_pc[31]}}, w_resume_pc};
   
   
   // SoC-level integration: instantiate henry_soc (core + MC/HPC3/IOC2 device models,
   // incl. the Z8530 SCC console TX + RR0) in place of the bare core.  Device-region
   // accesses (MC 0x1fa....., IOC2 0x1fbd98.., HPC3) are handled INSIDE henry_soc and
   // do NOT reach the external M00/DRAM bus; putchar_fifo_* is the merged SCC + core
   // console stream.  Ports the bare core exposed but henry_soc does not (single_step/
   // step, in_flush, *_state, branch_*, retire_op, dbg_trace_*, *_flush_done, the
   // retire_reg_valid bits) are tied off below -> FPGA single-step + trace/state
   // readback are inactive in the Henry build.
   henry_soc
     henrysoc0 (
	   .clk(s00_axi_aclk),
	   .reset(w_reset | w_rvcontrol[0]),
	   // SCC serial Rx driven by the ARM/PS via S00_AXI reg 0x3B (push) /
	   // reg 0x3A bit8 (full). A pushed byte lands in the core's Rx FIFO and
	   // raises the INT3 serial IRQ (IP2) inside henry_soc.
	   .scc_rx_valid(w_scc_rx_push),
	   .scc_rx_byte(w_scc_rx_data),
	   .scc_rx_full(w_scc_rx_full),
	   .resume(w_rvcontrol[1]),
	   .resume_pc(w_resume_pc64),
	   .ready_for_resume(w_ready),

	   .putchar_fifo_out(w_putchar_fifo_out),
	   .putchar_fifo_empty(w_putchar_fifo_empty),
	   .putchar_fifo_pop(w_putchar_fifo_pop),
	   .putchar_fifo_wptr(w_putchar_fifo_wptr),
	   .putchar_fifo_rptr(w_putchar_fifo_rptr),

	   .mem_req_valid(w_mem_req_valid),
	   .mem_req_addr(w_mem_req_addr),
	   .mem_req_store_data(w_mem_req_store_data),
	   .mem_req_opcode(w_mem_req_opcode),
	   .mem_req_mask(w_mem_req_mask),
	   .mem_rsp_valid(w_mem_rsp_valid),
	   .mem_rsp_bad(w_mem_rsp_bad),
	   .mem_rsp_load_data(w_load_data),

	   .retire_reg_ptr(w_reg_ptr0),
	   .retire_reg_data(w_reg_data0),
	   .retire_reg_two_ptr(w_reg_ptr1),
	   .retire_reg_two_data(w_reg_data1),
	   .retire_valid(w_pc_valid),
	   .retire_two_valid(w_pc2_valid),
	   .retire_pc(w_pc),
	   .retire_two_pc(w_pc2),

	   .got_break(w_got_break),
	   .got_ud(w_got_ud),
	   .got_bad_addr(w_got_bad_addr),
	   .dbg_head_pc(),
	   .took_irq(),
	   .epc(w_epc),
	   .status_reg(w_status_reg),
	   .badvaddr(w_badvaddr),
	   .cause(w_cause),
	   .core_state(w_state),
	   .l1i_state(w_istate),
	   .l1d_state(w_dstate),
	   .l2_state(w_l2state),
	   .l2_rsp_state(w_l2rsp_state),
	   .inflight(w_inflight),
	   .dbg_trace_index(w_trace_index),
	   .dbg_trace_data(w_trace_data),
	   .dbg_trace_wptr(w_trace_wptr),
	   .scsi_req_seq(w_scsi_req_seq),
	   .scsi_req_cdb(w_scsi_req_cdb),
	   .scsi_req_nbdp(w_scsi_req_nbdp),
	   .scsi_req_dest(w_scsi_req_dest),
	   .scsi_req_lun(w_scsi_req_lun),
	   .scsi_req_to_device(w_scsi_req_to_device),
	   .scsi_rsp_seq(w_scsi_rsp_seq),
	   .scsi_rsp_residual(w_scsi_rsp_residual),
	   .scsi_rsp_scsi_status(w_scsi_rsp_scsi_status),
	   .scsi_rsp_tgt_status(w_scsi_rsp_tgt_status),
	   .scsi_sel_delay(w_scsi_sel_delay)
	   );

   // tie-offs for status/debug taps henry_soc does not expose
   assign w_in_flush       = 1'b0;
   assign w_reg_val0       = 1'b0;
   assign w_reg_val1       = 1'b0;
   assign w_op             = 7'd0;
   assign w_op2            = 7'd0;
   assign w_branch_pc      = 32'd0;
   assign w_branch_val     = 1'b0;
   assign w_branch_fault   = 1'b0;
   // w_state/istate/dstate/l2state/l2rsp_state/inflight + trace now driven by henry_soc above
   assign w_l1i_flush_done = 1'b0;
   assign w_l1d_flush_done = 1'b0;
   assign w_l2_flush_done  = 1'b0;

endmodule
