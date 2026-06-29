
`timescale 1 ns / 1 ps

module axi_is_the_worst_v1_0_S00_AXI #
  (
   // Users to add parameters here
   
   // User parameters ends
   // Do not modify the parameters beyond this line
   
   // Width of S_AXI data bus
   parameter integer C_S_AXI_DATA_WIDTH = 32,
   parameter integer C_S_AXI_ADDR_WIDTH = 8
   )
   (
    // Users to add ports here
    output wire [31:0]			      controlreg,
    output wire [31:0]			      base,
    output wire [31:0]			      mask,
    input wire [31:0]			      status,
    
    input wire [7:0]			      putchar_fifo_out,
    input wire				      putchar_fifo_empty,
    output wire				      putchar_fifo_pop, 
    input wire [3:0]			      putchar_fifo_wptr,
    input wire [3:0]			      putchar_fifo_rptr,

    // SCC serial Rx: ARM/PS pushes a received byte into the core's Rx FIFO.
    // Protocol mirrors the putchar pop handshake: ARM writes reg 0x3B with
    // bit8=push + byte in [7:0]; we edge-detect bit8 -> 1-cycle scc_rx_push.
    // scc_rx_full is exposed in read reg 0x3A bit8 so the ARM polls before pushing.
    output wire				      scc_rx_push,
    output wire [7:0]			      scc_rx_data,
    input wire				      scc_rx_full,

    input wire [31:0]			      last_addr,
    input wire [31:0]			      last_data,
    input wire				      axi_busy,
    
    output wire [31:0]			      control,
    output wire [31:0]			      resume_pc,
    input wire [31:0]			      rvstatus,
    input wire [31:0]			      states,
    output wire				      sgi_mode,
    input wire [31:0]			      epc,
    input wire [31:0]                         status_reg,
    input wire [31:0]                         dbg_trace_data,
    input wire [8:0]                          dbg_trace_wptr,
    output wire [11:0]                        dbg_trace_index,
    input wire [31:0]			      badvaddr,
    input wire [4:0]			      cause,
    input wire				      l1i_flush_done,
    input wire				      l1d_flush_done,
    input wire				      l2_flush_done, 
    input wire [31:0]			      rv_mem_addr,
    input wire [31:0]			      pc,
    input wire [31:0]			      pc2,

    input wire [6:0]			      op,
    input wire [6:0]			      op2, 

    input wire				      branch_pc_valid,
    input wire [31:0]			      branch_pc,
    input wire				      branch_fault,

    input wire				      mem_rsp_valid,
    input wire [127:0]			      mem_rsp_load_data,
    input wire				      mem_req_valid,
    input wire [31:0]			      mem_req_addr,
    
    input wire				      pc_valid,
    input wire				      pc2_valid,

    input wire [4:0]			      retire_reg_ptr,
    input wire [31:0]			      retire_reg_data,
    input wire				      retire_reg_valid,
    
    input wire [4:0]			      retire_reg_two_ptr,
    input wire [31:0]			      retire_reg_two_data,
    input wire				      retire_reg_two_valid,
    
    input wire [63:0]			      l1i_cache_accesses,
    input wire [63:0]			      l1i_cache_hits,
    input wire [63:0]			      l1d_cache_accesses,
    input wire [63:0]			      l1d_cache_hits,
    input wire [63:0]			      l2_cache_accesses,
    input wire [63:0]			      l2_cache_hits,
    input wire [63:0]			      l2_early_accesses,
    input wire [63:0]			      branch_faults,

    input wire [63:0]			      dram_req_cnt,
    input wire [63:0]			      dram_req_cycles,
    input wire [63:0]			      axi_reads,
    input wire [63:0]			      axi_writes,
    output wire [31:0]			      max_fetches,
    input wire				      rv_reset,
    // ---- SCSI mailbox (host-served disk): request from henry (PS reads at 0x30-0x35);
    //      completion + tunable sel_delay written by the PS (slv_reg13/15/16/17). ----
    input  wire [31:0]			      scsi_req_seq,
    input  wire [127:0]			      scsi_req_cdb,
    input  wire [31:0]			      scsi_req_nbdp,
    input  wire [7:0]			      scsi_req_dest,
    input  wire [7:0]			      scsi_req_lun,
    input  wire				      scsi_req_to_device,
    output wire [31:0]			      scsi_rsp_seq,
    output wire [31:0]			      scsi_rsp_residual,
    output wire [7:0]			      scsi_rsp_scsi_status,
    output wire [7:0]			      scsi_rsp_tgt_status,
    output wire [15:0]			      scsi_sel_delay,

    // Global Clock Signal
    input wire				      S_AXI_ACLK,
    // Global Reset Signal. This Signal is Active LOW
    input wire				      S_AXI_ARESETN,
    // Write address (issued by master, acceped by Slave)
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0]     S_AXI_AWADDR,
    // Write channel Protection type. This signal indicates the
    // privilege and security level of the transaction, and whether
    // the transaction is a data access or an instruction access.
    input wire [2 : 0]			      S_AXI_AWPROT,
    // Write address valid. This signal indicates that the master signaling
    // valid write address and control information.
    input wire				      S_AXI_AWVALID,
    // Write address ready. This signal indicates that the slave is ready
    // to accept an address and associated control signals.
    output wire				      S_AXI_AWREADY,
    // Write data (issued by master, acceped by Slave) 
    input wire [C_S_AXI_DATA_WIDTH-1 : 0]     S_AXI_WDATA,
    // Write strobes. This signal indicates which byte lanes hold
    // valid data. There is one write strobe bit for each eight
    // bits of the write data bus.    
    input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
    // Write valid. This signal indicates that valid write
    // data and strobes are available.
    input wire				      S_AXI_WVALID,
    // Write ready. This signal indicates that the slave
    // can accept the write data.
    output wire				      S_AXI_WREADY,
    // Write response. This signal indicates the status
    // of the write transaction.
    output wire [1 : 0]			      S_AXI_BRESP,
    // Write response valid. This signal indicates that the channel
    // is signaling a valid write response.
    output wire				      S_AXI_BVALID,
    // Response ready. This signal indicates that the master
    // can accept a write response.
    input wire				      S_AXI_BREADY,
    // Read address (issued by master, acceped by Slave)
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0]     S_AXI_ARADDR,
    // Protection type. This signal indicates the privilege
    // and security level of the transaction, and whether the
    // transaction is a data access or an instruction access.
    input wire [2 : 0]			      S_AXI_ARPROT,
    // Read address valid. This signal indicates that the channel
    // is signaling valid read address and control information.
    input wire				      S_AXI_ARVALID,
    // Read address ready. This signal indicates that the slave is
    // ready to accept an address and associated control signals.
    output wire				      S_AXI_ARREADY,
    // Read data (issued by slave)
    output wire [C_S_AXI_DATA_WIDTH-1 : 0]    S_AXI_RDATA,
    // Read response. This signal indicates the status of the
    // read transfer.
    output wire [1 : 0]			      S_AXI_RRESP,
    // Read valid. This signal indicates that the channel is
    // signaling the required read data.
    output wire				      S_AXI_RVALID,
    // Read ready. This signal indicates that the master can
    // accept the read data and response information.
    input wire				      S_AXI_RREADY
    );

   //----------------------------------------------
   //-- Signals for user logic register space example
   //------------------------------------------------
   //-- Number of Slave Registers 64
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg0;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg1;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg2;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg3;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg4;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg5;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg6;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg7;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg8;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg9;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg10;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg11;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg12;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg13;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg14;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg15;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg16;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg17;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg18;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg19;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg20;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg21;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg22;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg23;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg24;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg25;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg26;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg27;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg28;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg29;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg30;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg31;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg32;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg33;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg34;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg35;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg36;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg37;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg38;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg39;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg40;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg41;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg42;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg43;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg44;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg45;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg46;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg47;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg48;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg49;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg50;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg51;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg52;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg53;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg54;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg55;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg56;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg57;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg58;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg59;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg60;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg61;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg62;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      slv_reg63;

   
   // AXI4LITE signals
   reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	      axi_awaddr;
   reg 					      axi_awready;
   reg 					      axi_wready;
   reg [1 : 0] 				      axi_bresp;
   reg 					      axi_bvalid;
   reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	      axi_araddr;
   reg 					      axi_arready;
   reg [C_S_AXI_DATA_WIDTH-1 : 0] 	      axi_rdata;
   reg [1 : 0] 				      axi_rresp;
   reg 					      axi_rvalid;

   reg [31:0] 				      r_last_pc;
   reg [63:0] 				      r_insn_cnt;
   reg [31:0]				      r_reg_writes;
   
   reg [63:0] 				      r_cycle;
   reg [63:0]				      r_axi_busy_cnt;
   
   wire					      w_core_stopped = |rvstatus[4:2];
   always@(posedge S_AXI_ACLK )
     begin
	if(S_AXI_ARESETN==1'b0 || slv_reg4[0])
	  begin
	     r_axi_busy_cnt <= 64'd0;
	  end
	else if(axi_busy & (w_core_stopped==1'b0))
	  begin
	     r_axi_busy_cnt <= r_axi_busy_cnt + 'd1;
	  end
     end // always@ (posedge S_AXI_ACLK )


   reg [31:0] r_last_retire;
   always@(posedge S_AXI_ACLK )
     begin
	if(S_AXI_ARESETN==1'b0 || slv_reg4[0])
	  begin
	     r_last_retire <= 32'd0;
	  end
	else
	  begin
	     if(pc_valid)
	       begin
		  r_last_retire <= 'd0;
	       end
	     else
	       begin
		  if((&r_last_retire[15:0]) == 1'b0)
		    begin
		       r_last_retire <= r_last_retire + 'd1;
		    end
	       end
	  end
     end // always@ (posedge S_AXI_ACLK )
   
   
   always@(posedge S_AXI_ACLK )
     begin
	if(S_AXI_ARESETN==1'b0 || slv_reg4[0])
	  begin
	     r_insn_cnt <= 64'd0;
	     r_reg_writes <= 32'd0;
	  end
	else
	  begin
	     if(pc2_valid)
	       begin
		  r_insn_cnt <= r_insn_cnt + 'd2;
	       end
	     else if(pc_valid)
	       begin
		  r_insn_cnt <= r_insn_cnt + 'd1;
	       end
	     if(retire_reg_two_valid)
	       begin
		  r_reg_writes <= r_reg_writes + 'd2;
	       end
	     else if(retire_reg_valid)
	       begin
		  r_reg_writes <= r_reg_writes + 'd1;
	       end
	  end
     end // always@ (posedge S_AXI_ACLK )

   always@(posedge S_AXI_ACLK )
     begin
	if(S_AXI_ARESETN==1'b0 || slv_reg4[0])
	  begin
	     r_last_pc <= 32'hdeadbeef;
	  end
	else
	  begin
	     if(pc2_valid)
	       r_last_pc <= pc2;
	     else if(pc_valid)
	       r_last_pc <= pc;
	  end // else: !if(S_AXI_ARESETN==1'b0 || slv_reg4[0])
     end // always@ (posedge S_AXI_ACLK )

   reg [31:0] r_arch_regs [31:0];
   
   always@(posedge S_AXI_ACLK )
     begin
	if(retire_reg_valid)
	  begin
	     r_arch_regs[retire_reg_ptr] <= retire_reg_data;
	  end
	if(retire_reg_two_valid)
	  begin
	     r_arch_regs[retire_reg_two_ptr] <= retire_reg_two_data;
	  end
     end // always@ (posedge S_AXI_ACLK )


   
   always@(posedge S_AXI_ACLK )
     begin
	if(S_AXI_ARESETN==1'b0 || slv_reg4[0])
	  begin
	     r_cycle <= 64'd0;
	  end
	else
	  begin
	     if(w_core_stopped == 1'b0)
	       begin
		  r_cycle <= r_cycle + 64'd1;
	       end
	  end
     end
       

   // Example-specific design signals
   // local parameter for addressing 32 bit / 64 bit C_S_AXI_DATA_WIDTH
   // ADDR_LSB is used for addressing 32/64 bit registers/memories
   // ADDR_LSB = 2 for 32 bits (n downto 2)
   // ADDR_LSB = 3 for 64 bits (n downto 3)
   localparam integer 			      ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
   localparam integer 			      OPT_MEM_ADDR_BITS = 5;
   wire 				      slv_reg_rden;
   wire 				      slv_reg_wren;
   reg [C_S_AXI_DATA_WIDTH-1:0] 	      reg_data_out;
   integer 				      byte_index;
   reg 					      aw_en;

   // I/O Connections assignments
   assign controlreg = slv_reg0;

   assign max_fetches = slv_reg2;	       
   assign control = slv_reg4;
   assign resume_pc = slv_reg5;
   assign base = slv_reg6;
   assign mask = slv_reg8;
   assign sgi_mode = slv_reg12[0];
   assign dbg_trace_index = slv_reg23[11:0];   // trace buffer read index {row[7:0],word[3:0]}
   // SCSI completion (PS -> henry): the ARM writes these then echoes the doorbell.
   assign scsi_rsp_seq         = slv_reg13;        // write 0x0D (echo scsi_req_seq when done)
   assign scsi_rsp_residual    = slv_reg15;        // write 0x0F
   assign scsi_rsp_scsi_status = slv_reg16[7:0];   // write 0x10 = {tgt[15:8], scsi[7:0]}
   assign scsi_rsp_tgt_status  = slv_reg16[15:8];
   assign scsi_sel_delay       = slv_reg17[15:0];  // write 0x11 (0 => shim default 8192)

   
   assign S_AXI_AWREADY	= axi_awready;
   assign S_AXI_WREADY	= axi_wready;
   assign S_AXI_BRESP	= axi_bresp;
   assign S_AXI_BVALID	= axi_bvalid;
   assign S_AXI_ARREADY	= axi_arready;
   assign S_AXI_RDATA	= axi_rdata;
   assign S_AXI_RRESP	= axi_rresp;
   assign S_AXI_RVALID	= axi_rvalid;
   // Implement axi_awready generation
   // axi_awready is asserted for one S_AXI_ACLK clock cycle when both
   // S_AXI_AWVALID and S_AXI_WVALID are asserted. axi_awready is
   // de-asserted when reset is low.

   always @( posedge S_AXI_ACLK )
     begin
	if ( S_AXI_ARESETN == 1'b0 )
	  begin
	     axi_awready <= 1'b0;
	     aw_en <= 1'b1;
	  end 
	else
	  begin    
	     if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
	       begin
	          // slave is ready to accept write address when 
	          // there is a valid write address and write data
	          // on the write address and data bus. This design 
	          // expects no outstanding transactions. 
	          axi_awready <= 1'b1;
	          aw_en <= 1'b0;
	       end
	     else if (S_AXI_BREADY && axi_bvalid)
	       begin
	          aw_en <= 1'b1;
	          axi_awready <= 1'b0;
	       end
	     else           
	       begin
	          axi_awready <= 1'b0;
	       end
	  end 
     end       

   // Implement axi_awaddr latching
   // This process is used to latch the address when both 
   // S_AXI_AWVALID and S_AXI_WVALID are valid. 

   always @( posedge S_AXI_ACLK )
     begin
	if ( S_AXI_ARESETN == 1'b0 )
	  begin
	     axi_awaddr <= 0;
	  end 
	else
	  begin    
	     if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
	       begin
	          // Write Address latching 
	          axi_awaddr <= S_AXI_AWADDR;
	       end
	  end 
     end       

   // Implement axi_wready generation
   // axi_wready is asserted for one S_AXI_ACLK clock cycle when both
   // S_AXI_AWVALID and S_AXI_WVALID are asserted. axi_wready is 
   // de-asserted when reset is low. 

   always @( posedge S_AXI_ACLK )
     begin
	if ( S_AXI_ARESETN == 1'b0 )
	  begin
	     axi_wready <= 1'b0;
	  end 
	else
	  begin    
	     if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en )
	       begin
	          // slave is ready to accept write data when 
	          // there is a valid write address and write data
	          // on the write address and data bus. This design 
	          // expects no outstanding transactions. 
	          axi_wready <= 1'b1;
	       end
	     else
	       begin
	          axi_wready <= 1'b0;
	       end
	  end 
     end       

   // Implement memory mapped register select and write logic generation
   // The write data is accepted and written to memory mapped registers when
   // axi_awready, S_AXI_WVALID, axi_wready and S_AXI_WVALID are asserted. Write strobes are used to
   // select byte enables of slave registers while writing.
   // These registers are cleared when reset (active low) is applied.
   // Slave register write enable is asserted when valid address and data are available
   // and the slave is ready to accept the write address and write data.
   assign slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

   reg r_putchar_fifo_pop, n_putchar_fifo_pop;
   reg r_popchar, n_popchar;
   wire	w_reset = (S_AXI_ARESETN == 1'b0) | rv_reset;
   
   always @( posedge S_AXI_ACLK )
     begin
	if(w_reset)
	  begin
	     r_putchar_fifo_pop <= 1'b0;
	     r_popchar <= 1'b0;
	  end
	else
	  begin
	     r_putchar_fifo_pop <= n_putchar_fifo_pop;
	     r_popchar <= n_popchar;
	  end
     end // always @ ( posedge S_AXI_ACLK )


   
   always@(*)
     begin
	n_popchar = r_popchar;
	n_putchar_fifo_pop = 1'b0;
	if(r_popchar==1'b0)
	  begin
	     if(slv_reg58[0])
	       begin
		  n_putchar_fifo_pop = 1'b1;
		  n_popchar = 1'b1;
	       end
	  end
	else
	  begin
	     if((slv_reg58[0] == 1'b0) )
	       begin
		  n_popchar = 1'b0;
	       end
	  end // else: !if(r_popchar==1'b0)
     end // always@ (*)
   
   
   assign putchar_fifo_pop = r_putchar_fifo_pop;

   // SCC Rx push: edge-detect slv_reg59[8] (ARM write to reg 0x3B) into a
   // 1-cycle scc_rx_push pulse, mirroring the putchar pop handshake above.
   reg r_scc_rx_push, n_scc_rx_push;
   reg r_pushchar, n_pushchar;
   always @( posedge S_AXI_ACLK )
     begin
	if(w_reset)
	  begin
	     r_scc_rx_push <= 1'b0;
	     r_pushchar <= 1'b0;
	  end
	else
	  begin
	     r_scc_rx_push <= n_scc_rx_push;
	     r_pushchar <= n_pushchar;
	  end
     end
   always@(*)
     begin
	n_pushchar = r_pushchar;
	n_scc_rx_push = 1'b0;
	if(r_pushchar==1'b0)
	  begin
	     if(slv_reg59[8])
	       begin
		  n_scc_rx_push = 1'b1;
		  n_pushchar = 1'b1;
	       end
	  end
	else
	  begin
	     if((slv_reg59[8] == 1'b0) )
	       begin
		  n_pushchar = 1'b0;
	       end
	  end
     end
   assign scc_rx_push = r_scc_rx_push;
   assign scc_rx_data = slv_reg59[7:0];
   always @( posedge S_AXI_ACLK )
     begin
	if ( S_AXI_ARESETN == 1'b0 )
	  begin
	     slv_reg0 <= 0;
	     slv_reg1 <= 0;
	     slv_reg2 <= 0;
	     slv_reg3 <= 0;
	     slv_reg4 <= 0;
	     slv_reg5 <= 0;
	     slv_reg6 <= 0;
	     slv_reg7 <= 0;
	     slv_reg8 <= 0;
	     slv_reg9 <= 0;
	     slv_reg10 <= 0;
	     slv_reg11 <= 0;
	     slv_reg12 <= 0;
	     slv_reg13 <= 0;
	     slv_reg14 <= 0;
	     slv_reg15 <= 0;
	     slv_reg16 <= 0;
	     slv_reg17 <= 0;
	     slv_reg18 <= 0;
	     slv_reg19 <= 0;
	     slv_reg20 <= 0;
	     slv_reg21 <= 0;
	     slv_reg22 <= 0;
	     slv_reg23 <= 0;
	     slv_reg24 <= 0;
	     slv_reg25 <= 0;
	     slv_reg26 <= 0;
	     slv_reg27 <= 0;
	     slv_reg28 <= 0;
	     slv_reg29 <= 0;
	     slv_reg30 <= 0;
	     slv_reg31 <= 0;
	     slv_reg32 <= 0;
	     slv_reg33 <= 0;
	     slv_reg34 <= 0;
	     slv_reg35 <= 0;
	     slv_reg36 <= 0;
	     slv_reg37 <= 0;
	     slv_reg38 <= 0;
	     slv_reg39 <= 0;
	     slv_reg40 <= 0;
	     slv_reg41 <= 0;
	     slv_reg42 <= 0;
	     slv_reg43 <= 0;
	     slv_reg44 <= 0;
	     slv_reg45 <= 0;
	     slv_reg46 <= 0;
	     slv_reg47 <= 0;
	     slv_reg48 <= 0;
	     slv_reg49 <= 0;
	     slv_reg50 <= 0;
	     slv_reg51 <= 0;
	     slv_reg52 <= 0;
	     slv_reg53 <= 0;
	     slv_reg54 <= 0;
	     slv_reg55 <= 0;
	     slv_reg56 <= 0;
	     slv_reg57 <= 0;
	     slv_reg58 <= 0;
	     slv_reg59 <= 0;
	     slv_reg60 <= 0;
	     slv_reg61 <= 0;
	     slv_reg62 <= 0;
	     slv_reg63 <= 0;
	  end 
	else begin
	   if (slv_reg_wren)
	     begin
	        case ( axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] )
	          6'h00:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 0
	                 slv_reg0[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h01:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 1
	                 slv_reg1[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h02:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 2
	                 slv_reg2[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h03:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 3
	                 slv_reg3[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h04:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 4
	                 slv_reg4[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h05:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 5
	                 slv_reg5[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h06:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 6
	                 slv_reg6[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h07:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 7
	                 slv_reg7[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h08:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 8
	                 slv_reg8[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h09:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 9
	                 slv_reg9[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h0A:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 10
	                 slv_reg10[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h0B:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 11
	                 slv_reg11[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h0C:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 12
	                 slv_reg12[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h0D:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 13
	                 slv_reg13[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h0E:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 14
	                 slv_reg14[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h0F:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 15
	                 slv_reg15[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h10:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 16
	                 slv_reg16[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h11:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 17
	                 slv_reg17[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h12:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 18
	                 slv_reg18[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h13:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 19
	                 slv_reg19[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h14:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 20
	                 slv_reg20[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h15:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 21
	                 slv_reg21[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h16:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 22
	                 slv_reg22[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h17:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 23
	                 slv_reg23[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h18:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 24
	                 slv_reg24[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h19:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 25
	                 slv_reg25[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h1A:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 26
	                 slv_reg26[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h1B:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 27
	                 slv_reg27[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h1C:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 28
	                 slv_reg28[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h1D:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 29
	                 slv_reg29[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h1E:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 30
	                 slv_reg30[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h1F:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 31
	                 slv_reg31[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h20:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 32
	                 slv_reg32[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h21:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 33
	                 slv_reg33[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h22:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 34
	                 slv_reg34[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h23:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 35
	                 slv_reg35[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h24:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 36
	                 slv_reg36[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h25:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 37
	                 slv_reg37[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h26:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 38
	                 slv_reg38[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h27:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 39
	                 slv_reg39[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h28:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 40
	                 slv_reg40[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h29:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 41
	                 slv_reg41[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h2A:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 42
	                 slv_reg42[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h2B:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 43
	                 slv_reg43[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h2C:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 44
	                 slv_reg44[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h2D:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 45
	                 slv_reg45[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h2E:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 46
	                 slv_reg46[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h2F:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 47
	                 slv_reg47[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h30:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 48
	                 slv_reg48[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h31:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 49
	                 slv_reg49[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h32:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 50
	                 slv_reg50[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h33:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 51
	                 slv_reg51[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h34:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 52
	                 slv_reg52[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h35:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 53
	                 slv_reg53[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h36:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 54
	                 slv_reg54[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h37:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 55
	                 slv_reg55[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h38:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 56
	                 slv_reg56[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h39:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 57
	                 slv_reg57[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h3A:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 58
	                 slv_reg58[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h3B:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 59
	                 slv_reg59[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h3C:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 60
	                 slv_reg60[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h3D:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 61
	                 slv_reg61[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h3E:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 62
	                 slv_reg62[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          6'h3F:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                 // Respective byte enables are asserted as per write strobes 
	                 // Slave register 63
	                 slv_reg63[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          default : begin
	             slv_reg0 <= slv_reg0;		     
	             slv_reg1 <= slv_reg1;
	             slv_reg2 <= slv_reg2;
	             slv_reg3 <= slv_reg3;
	             slv_reg4 <= slv_reg4;
	             slv_reg5 <= slv_reg5;
	             slv_reg6 <= slv_reg6;
	             slv_reg7 <= slv_reg7;
	             slv_reg8 <= slv_reg8;
	             slv_reg9 <= slv_reg9;
	             slv_reg10 <= slv_reg10;
	             slv_reg11 <= slv_reg11;
	             slv_reg12 <= slv_reg12;
	             slv_reg13 <= slv_reg13;
	             slv_reg14 <= slv_reg14;
	             slv_reg15 <= slv_reg15;
	             slv_reg16 <= slv_reg16;
	             slv_reg17 <= slv_reg17;
	             slv_reg18 <= slv_reg18;
	             slv_reg19 <= slv_reg19;
	             slv_reg20 <= slv_reg20;
	             slv_reg21 <= slv_reg21;
	             slv_reg22 <= slv_reg22;
	             slv_reg23 <= slv_reg23;
	             slv_reg24 <= slv_reg24;
	             slv_reg25 <= slv_reg25;
	             slv_reg26 <= slv_reg26;
	             slv_reg27 <= slv_reg27;
	             slv_reg28 <= slv_reg28;
	             slv_reg29 <= slv_reg29;
	             slv_reg30 <= slv_reg30;
	             slv_reg31 <= slv_reg31;
	             slv_reg32 <= slv_reg32;
	             slv_reg33 <= slv_reg33;
	             slv_reg34 <= slv_reg34;
	             slv_reg35 <= slv_reg35;
	             slv_reg36 <= slv_reg36;
	             slv_reg37 <= slv_reg37;
	             slv_reg38 <= slv_reg38;
	             slv_reg39 <= slv_reg39;
	             slv_reg40 <= slv_reg40;
	             slv_reg41 <= slv_reg41;
	             slv_reg42 <= slv_reg42;
	             slv_reg43 <= slv_reg43;
	             slv_reg44 <= slv_reg44;
	             slv_reg45 <= slv_reg45;
	             slv_reg46 <= slv_reg46;
	             slv_reg47 <= slv_reg47;
	             slv_reg48 <= slv_reg48;
	             slv_reg49 <= slv_reg49;
	             slv_reg50 <= slv_reg50;
	             slv_reg51 <= slv_reg51;
	             slv_reg52 <= slv_reg52;
	             slv_reg53 <= slv_reg53;
	             slv_reg54 <= slv_reg54;
	             slv_reg55 <= slv_reg55;
	             slv_reg56 <= slv_reg56;
	             slv_reg57 <= slv_reg57;
	             slv_reg58 <= slv_reg58;
	             slv_reg59 <= slv_reg59;
	             slv_reg60 <= slv_reg60;
	             slv_reg61 <= slv_reg61;
	             slv_reg62 <= slv_reg62;
	             slv_reg63 <= slv_reg63;
	          end
	        endcase
	     end // if (slv_reg_wren)
	   else
	     begin
		slv_reg0 <= slv_reg0[31] ? {1'b0, slv_reg0[30:0]} : slv_reg0;
	     end
	end
     end // always @ ( posedge S_AXI_ACLK )
   

   // Implement write response logic generation
   // The write response and response valid signals are asserted by the slave 
   // when axi_wready, S_AXI_WVALID, axi_wready and S_AXI_WVALID are asserted.  
   // This marks the acceptance of address and indicates the status of 
   // write transaction.

   always @( posedge S_AXI_ACLK )
     begin
	if ( S_AXI_ARESETN == 1'b0 )
	  begin
	     axi_bvalid  <= 0;
	     axi_bresp   <= 2'b0;
	  end 
	else
	  begin    
	     if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID)
	       begin
	          // indicates a valid write response is available
	          axi_bvalid <= 1'b1;
	          axi_bresp  <= 2'b0; // 'OKAY' response 
	       end                   // work error responses in future
	     else
	       begin
	          if (S_AXI_BREADY && axi_bvalid) 
	            //check if bready is asserted while bvalid is high) 
	            //(there is a possibility that bready is always asserted high)   
	            begin
	               axi_bvalid <= 1'b0; 
	            end  
	       end
	  end
     end   

   // Implement axi_arready generation
   // axi_arready is asserted for one S_AXI_ACLK clock cycle when
   // S_AXI_ARVALID is asserted. axi_awready is 
   // de-asserted when reset (active low) is asserted. 
   // The read address is also latched when S_AXI_ARVALID is 
   // asserted. axi_araddr is reset to zero on reset assertion.

   always @( posedge S_AXI_ACLK )
     begin
	if ( S_AXI_ARESETN == 1'b0 )
	  begin
	     axi_arready <= 1'b0;
	     axi_araddr  <= 32'b0;
	  end 
	else
	  begin    
	     if (~axi_arready && S_AXI_ARVALID)
	       begin
	          // indicates that the slave has acceped the valid read address
	          axi_arready <= 1'b1;
	          // Read address latching
	          axi_araddr  <= S_AXI_ARADDR;
	       end
	     else
	       begin
	          axi_arready <= 1'b0;
	       end
	  end 
     end       

   // Implement axi_arvalid generation
   // axi_rvalid is asserted for one S_AXI_ACLK clock cycle when both 
   // S_AXI_ARVALID and axi_arready are asserted. The slave registers 
   // data are available on the axi_rdata bus at this instance. The 
   // assertion of axi_rvalid marks the validity of read data on the 
   // bus and axi_rresp indicates the status of read transaction.axi_rvalid 
   // is deasserted on reset (active low). axi_rresp and axi_rdata are 
   // cleared to zero on reset (active low).  
   always @( posedge S_AXI_ACLK )
     begin
	if ( S_AXI_ARESETN == 1'b0 )
	  begin
	     axi_rvalid <= 0;
	     axi_rresp  <= 0;
	  end 
	else
	  begin    
	     if (axi_arready && S_AXI_ARVALID && ~axi_rvalid)
	       begin
	          // Valid read data is available at the read data bus
	          axi_rvalid <= 1'b1;
	          axi_rresp  <= 2'b0; // 'OKAY' response
	       end   
	     else if (axi_rvalid && S_AXI_RREADY)
	       begin
	          // Read data is accepted by the master
	          axi_rvalid <= 1'b0;
	       end                
	  end
     end    

   // Implement memory mapped register select and read logic generation
   // Slave register read enable is asserted when valid address is available
   // and the slave is ready to accept the read address.
   assign slv_reg_rden = axi_arready & S_AXI_ARVALID & ~axi_rvalid;
   always @(*)
     begin
	// Address decoding for reading registers
	case ( axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] )
	  6'h00   : reg_data_out <= r_insn_cnt[31:0];
	  6'h01   : reg_data_out <= status;
	  6'h02   : reg_data_out <= slv_reg2;
	  6'h03   : reg_data_out <= rvstatus;
	  6'h04   : reg_data_out <= slv_reg4; //control
	  6'h05   : reg_data_out <= slv_reg5; //resume pc
	  6'h06   : reg_data_out <= slv_reg6; //base
	  6'h07   : reg_data_out <= r_last_pc;
	  6'h08   : reg_data_out <= 32'h7370696d;
	  6'h09   : reg_data_out <= last_addr; 
	  6'h0A   : reg_data_out <= rvstatus; 
	  6'h0B   : reg_data_out <= epc;//
	  6'h0C   : reg_data_out <= badvaddr;
	  6'h0D   : reg_data_out <= states;
	  6'h0E   : reg_data_out <= r_arch_regs[slv_reg14[4:0]];
	  6'h0F   : reg_data_out <= rv_mem_addr;
	  6'h10   : reg_data_out <= r_axi_busy_cnt[31:0];
	  6'h11   : reg_data_out <= r_axi_busy_cnt[63:32];
	  6'h12   : reg_data_out <= axi_reads[31:0];
	  6'h13   : reg_data_out <= axi_reads[63:32];
	  6'h14   : reg_data_out <= axi_writes[31:0];
	  6'h15   : reg_data_out <= axi_writes[63:32];
	  6'h16   : reg_data_out <= status_reg;
	  6'h17   : reg_data_out <= slv_reg23;
	  6'h18   : reg_data_out <= dbg_trace_data;
	  6'h19   : reg_data_out <= {23'd0, dbg_trace_wptr};
	  6'h1A   : reg_data_out <= slv_reg26;
	  6'h1B   : reg_data_out <= slv_reg27;
	  6'h1C   : reg_data_out <= slv_reg28;
	  6'h1D   : reg_data_out <= slv_reg29;
	  6'h1E   : reg_data_out <= slv_reg30;
	  6'h1F   : reg_data_out <= slv_reg31;
	  6'h20   : reg_data_out <= slv_reg32;
	  6'h21   : reg_data_out <= slv_reg33;
	  6'h22   : reg_data_out <= slv_reg34;
	  6'h23   : reg_data_out <= slv_reg35;
	  6'h24   : reg_data_out <= slv_reg36;
	  6'h25   : reg_data_out <= slv_reg37;
	  6'h26   : reg_data_out <= {24'd0, l2_flush_done, l1i_flush_done, l1d_flush_done, cause};
	  6'h27   : reg_data_out <= r_last_retire;
	  6'h28   : reg_data_out <= r_insn_cnt[31:0];
	  6'h29   : reg_data_out <= r_insn_cnt[63:32];
	  6'h2A   : reg_data_out <= r_cycle[31:0];
	  6'h2B   : reg_data_out <= r_cycle[63:32];
	  6'h2C   : reg_data_out <= l1i_cache_accesses[31:0];
	  6'h2D   : reg_data_out <= l1i_cache_accesses[63:32];
	  6'h2E   : reg_data_out <= l1i_cache_hits[31:0];
	  6'h2F   : reg_data_out <= l1i_cache_hits[63:32];
	  // SCSI request mailbox (was L1D/L2 cache perf counters): PS reads the pending
	  // command here; 0x30 is the doorbell (++ per command) the ARM polls.
	  6'h30   : reg_data_out <= scsi_req_seq;
	  6'h31   : reg_data_out <= scsi_req_cdb[31:0];
	  6'h32   : reg_data_out <= scsi_req_cdb[63:32];
	  6'h33   : reg_data_out <= scsi_req_cdb[95:64];
	  6'h34   : reg_data_out <= scsi_req_nbdp;
	  6'h35   : reg_data_out <= {15'd0, scsi_req_to_device, scsi_req_lun, scsi_req_dest};
	  6'h36   : reg_data_out <= l2_cache_hits[31:0];
	  6'h37   : reg_data_out <= l2_cache_hits[63:32];
	  6'h38   : reg_data_out <= branch_faults[31:0];
	  6'h39   : reg_data_out <= branch_faults[63:32];
	  6'h3A   : reg_data_out <= {23'd0, scc_rx_full, putchar_fifo_rptr, putchar_fifo_wptr};
	  6'h3B   : reg_data_out <= {24'd0, putchar_fifo_out};
	  6'h3C   : reg_data_out <= dram_req_cnt[31:0];
	  6'h3D   : reg_data_out <= dram_req_cnt[63:32];
	  6'h3E   : reg_data_out <= dram_req_cycles[31:0];
	  6'h3F   : reg_data_out <= dram_req_cycles[63:32];
	  default : reg_data_out <= 0;
	endcase
     end

   // Output register or memory read data
   always @( posedge S_AXI_ACLK )
     begin
	if ( S_AXI_ARESETN == 1'b0 )
	  begin
	     axi_rdata  <= 0;
	  end 
	else
	  begin    
	     // When there is a valid read address (S_AXI_ARVALID) with 
	     // acceptance of read address by the slave (axi_arready), 
	     // output the read dada 
	     if (slv_reg_rden)
	       begin
	          axi_rdata <= reg_data_out;     // register read data
	       end   
	  end
     end    

   // Add user logic here

   // User logic ends

endmodule
    
