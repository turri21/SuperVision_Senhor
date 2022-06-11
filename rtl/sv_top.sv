module supervision
(
	input               clk_sys,
	input               reset,
	input [7:0]         joystick,
	input [7:0]         rom_dout,
	input [3:0]         user_in,
	input               large_rom,
	output              hsync,
	output              hblank,
	output              vsync,
	output              vblank,
	output [15:0]       audio_r,
	output [15:0]       audio_l,
	output [1:0]        pixel,
	output              pix_ce,
	output [18:0]       addr_bus,
	output              rom_read,
	output reg [7:0]    link_ddr,
	output reg [7:0]    link_data
);

wire phi1 = sys_div == 2'b00;
wire phi2 = sys_div == 2'b10;
reg [1:0] sys_div = 0;

//////////////////////////////////////////////////////////////////

reg [7:0] sys_ctl;
reg [7:0] irq_timer; // 2023
reg irq_tim;
wire irq_dma_n;

wire [15:0] cpu_addr;
wire [7:0] cpu_dout;
wire [7:0] wram_dout;
wire [7:0] vram_dout;
wire [7:0] sys_dout;

wire dma_en;
wire dma_dir;

wire adma_read;

wire [7:0] lcd_din;
wire cpu_rdy = ~dma_en && ~adma_read;
wire cpu_we;

wire [15:0] lcd_addr;
wire [15:0] adma_addr;
wire [15:0] dma_addr;
wire [15:0] vram_addr;

wire [5:0] audio_ch1, audio_ch2;

////////////////////// IRQ //////////////////////////
reg [15:0] nmi_clk;

assign addr_bus = {2'b11, rom_addr};
assign rom_read = rom_cs & ~phi1;
assign audio_l = { audio_ch2, 10'd0 };
assign audio_r = { audio_ch1, 10'd0 };

// irq status
reg irq_pending = 0;
wire nmi = &nmi_clk & sys_ctl[0];
wire timer_tap = (sys_ctl[4] ? nmi_clk[13] : nmi_clk[7]);

always @(posedge clk_sys) begin
	reg old_tap;

	sys_div <= sys_div + 1'd1;

	if (phi1) begin
		old_tap <= timer_tap;
		nmi_clk <= nmi_clk + 16'b1;
			
		if (~old_tap && timer_tap) begin
			if (irq_timer > 0) begin
				irq_timer <= irq_timer - 8'b1;
				if (irq_timer == 1)
						irq_pending <= 1;
			end
		end
	
		if (irq_pending && ~timer_tap) begin
			irq_pending <= 0;
			irq_tim <= 1;
		end

		if (sys_cs && cpu_we && AB[2:0] == 3'h3) begin
			irq_timer <= cpu_dout;
			if (cpu_dout == 0) begin
				if (~timer_tap) begin
					irq_tim <= 1;
				end else begin
					irq_pending <= 1;
				end
			end
		end
		
		if (sys_cs && AB[2:0] == 3'h4) begin // write to irq timer ack
			irq_tim <= 0;
		end
	end

	if (phi2) begin
		DI <= sys_cs ? sys_dout :
		wram_cs ? wram_dout :
		vram_cs ? vram_dout :
		rom_cs ? rom_dout : 8'hff;
		
		if (sys_cs && cpu_we) begin
			case (AB[2:0])
				3'h1: link_ddr <= cpu_dout;
				3'h2: link_data <= cpu_dout;
				3'h6: sys_ctl <= cpu_dout;
			endcase
		end
	end

	if (reset) begin
		DI <= 0;
		irq_tim <= 0;
		irq_pending <= 0;
		irq_timer <= 0;
		nmi_clk <= 0;
		sys_ctl <= 8'h00; // This seems needed for Journey to the West bank scheme
		link_ddr <= 8'h00;
		link_data <= 8'h00;
	end

end

/////////////////////////// MEMORY MAP /////////////////////

// 0000 - 1FFF - WRAM
// 2000 - 202F - CTRL
// 2030 - 3FFF - CTRL - mirrors ??
// 4000 - 5FFF - VRAM ??
// 6000 - 7FFF - VRAM - mirrors ??
// 8000 - BFFF - banks
// C000 - FFFF - last 16k of cartridge

wire [15:0] AB = adma_read ? adma_addr : (dma_en ? dma_addr : cpu_addr);

wire wram_cs = AB ==? 16'b000x_xxxx_xxxx_xxxx;
wire lcd_cs  = AB ==? 16'b0010_0000_0000_0xxx; // match 2000-2007 LCD control registers
wire dma_cs  = AB ==? 16'b0010_0000_0000_1xxx; // match 2008-200F DMA control registers
wire snd_cs  = AB ==? 16'b0010_0000_0001_xxxx; // match 2010-201F sound registers
wire sys_cs  = AB ==? 16'b0010_0000_0010_0xxx; // match 2020-2027 sys registers
wire noi_cs  = AB ==? 16'b0010_0000_0010_1xxx; // match 2028-202F sound registers (noise)
wire vram_cs = AB ==? 16'b01xx_xxxx_xxxx_xxxx;
wire rom_cs  = AB ==? 16'b1xxx_xxxx_xxxx_xxxx;
wire rom_hi  = AB ==? 16'b11xx_xxxx_xxxx_xxxx;

reg [7:0] DI;

wire [2:0] adma_bank;

wire [7:0] DO = dma_en ? (dma_dir ? DII : vram_dout) : cpu_dout;
// wire wram_we = wram_cs ? cpu_we : 1'b0;
// wire vram_we = dma_en ? dma_dir : vram_cs ? cpu_we : 1'b0;

wire [2:0] b = AB[14] ? 3'b111 : adma_read ? adma_bank : sys_ctl[7:5];
//wire [16:0] banked_addr = (rom_hi ? {1'b1, AB} : (adma_read ? {adma_bank, AB[13:0]} : {sys_ctl[7:5], AB[13:0]}));
wire [18:0] magnum_addr = {(b[2] ? 4'b1111 : link_data[3:0]), b[0], AB[13:0]};
wire [18:0] rom_addr = large_rom ? magnum_addr : {2'b11, b, AB[13:0]};

wire irq_tim_masked = irq_tim & sys_ctl[1];
wire irq_dma_masked = ~irq_dma_n & sys_ctl[2];
wire nmi_masked = nmi & sys_ctl[0];
wire cpu_rwn;

assign cpu_we = adma_read ? 1'b0 : dma_en ? ~dma_dir : ~cpu_rwn;

wire [7:0] DII = sys_cs ? sys_dout :
	wram_cs ? wram_dout :
	vram_cs ? vram_dout :
	rom_cs ? rom_dout : 8'hff;

// read sys registers
always @* begin
	sys_dout = 8'hFF;
	if (~cpu_we) begin
		case (AB[2:0])
			3'h0: sys_dout = ~joystick;
			3'h1: sys_dout = {4'b0000, (user_in[3:0] & link_ddr[3:0]) | (link_data[3:0] & ~link_ddr[3:0])};
			3'h3: sys_dout = irq_timer;
			3'h6: sys_dout = sys_ctl;
			3'h7: sys_dout = {6'd0, ~irq_dma_n, irq_tim};
			default: sys_dout = 8'hFF;
		endcase
	end
end

spram #(.addr_width(13)) wram
(
	.clock(clk_sys),
	.address(AB[12:0]),
	.data(DO),
	.wren(cpu_we && wram_cs && phi2),
	.q(wram_dout)
);

dpram #(.addr_width(13)) vram
(
	.clock(clk_sys),
	.address_a(dma_en ? vram_addr : AB[12:0]),
	.data_a(DO),
	.q_a(vram_dout),
	.wren_a((dma_en ? dma_dir : (vram_cs && cpu_we)) && phi2),

	.address_b(lcd_addr),
	.q_b(lcd_din)
);

dma dma
(
	.clk        (clk_sys),
	.ce         (phi1),
	.reset      (reset),
	.AB         (AB[5:0]),
	.cpu_rnw    (~cpu_we),
	.dma_cs     (dma_cs && ~dma_en),
	.lcd_en     (0/*sys_ctl[3]*/),
	.data_in    (cpu_dout),
	.vbus_addr  (vram_addr),
	.cbus_addr  (dma_addr),
	.dma_en     (dma_en),
	.dma_dir    (dma_dir)
);

audio audio
(
	.clk(clk_sys),
	.ce(phi1),
	.reset(reset),
	.cpu_rwn(~cpu_we),
	.snd_cs(snd_cs | noi_cs | sys_cs),
	.AB(cpu_addr[5:0]),
	.dbus_in(adma_read ? DII : cpu_dout),
	.adma_irq_n(irq_dma_n),
	.prescaler(nmi_clk),
	.adma_read(adma_read),
	.adma_bank(adma_bank),
	.adma_addr(adma_addr),

	.CH1(audio_ch1),
	.CH2(audio_ch2)
);

lcd lcd
(
	.clk        (clk_sys),
	.ce         (phi2),
	.reset      (reset),
	.lcd_cs     (lcd_cs),
	.cpu_rwn    (~cpu_we),
	.AB         (AB[5:0]),
	.dbus_in    (cpu_dout),
	.ce_pix     (pix_ce),
	.pixel      (pixel),
	.lcd_off    (~sys_ctl[3] || (cpu_we && cpu_addr == 16'h2026)),
	.vram_data  (lcd_din),
	.vram_addr  (lcd_addr),
	.hsync      (hsync),
	.vsync      (vsync),
	.hblank     (hblank),
	.vblank     (vblank)
);

r65c02_tc cpu3
(
	.clk_clk_i    (clk_sys),
	.d_i          (DI),
	.ce           (phi1 && cpu_rdy),
	.irq_n_i      (~(irq_tim_masked | irq_dma_masked)),
	.nmi_n_i      (~nmi_masked),
	.rdy_i        (1), // This system seems to halt the clock for dma rather than use traditional rdy
	.rst_rst_n_i  (~reset),
	.so_n_i       (1),
	.a_o          (cpu_addr),
	.d_o          (cpu_dout),
	.rd_o         (),
	.sync_o       (),
	.wr_n_o       (cpu_rwn),
	.wr_o         ()
);

endmodule