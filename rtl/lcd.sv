module lcd
(

	input           clk, // clk_sys
	input           ce,
	input           reset,
	input           lcd_cs,
	input           cpu_rwn,
	input [5:0]     AB,
	input [7:0]     dbus_in,
	input [7:0]     vram_data,
	input           lcd_off,
	output          ce_pix,
	output reg [1:0]pixel,
	output [12:0]   vram_addr,
	output          hsync,
	output          vsync,
	output reg      hblank,
	output reg      vblank
);

localparam H_WIDTH = 9'd300;
localparam V_HEIGHT = 9'd262;

reg [7:0] lcd_xsize, lcd_ysize, lcd_xscroll, lcd_yscroll, ybuff, xbuff;


reg lcd_off_latch;

// 78720 cycles per two fields
// 300 cycles per line (120 spare cycles per frame)


reg [8:0] hblank_start, hblank_end, vblank_start, vblank_end, vpos, hpos, vpos_field, hpos_field;

reg [31:0] dot_count, frame_len;
wire [9:0] vpos_off = (vpos - vblank_end) + ybuff;
wire [9:0] hpos_off = (hpos - hblank_end) + xbuff;

wire [9:0] vpos_field_off = vpos_field + lcd_yscroll;
wire [9:0] hpos_field_off = hpos_field + lcd_xscroll[7:2];

wire [9:0] vpos_wrap = vpos_off > 169 && xbuff < 8'h1C ? vpos_off - 10'd170 : vpos_off;

wire [9:0] vpos_field_wrap = vpos_field_off > 169 && lcd_xscroll < 8'h1C ? vpos_field_off - 10'd170 : vpos_field_off;


wire [7:0] hpos_div_4 = hpos_off[9:2];

reg [2:0] pix_off;

wire [12:0] video_addr = (vpos_wrap * 8'h30) + hpos_div_4;

initial begin
	hblank_end = 8'd70;
	vblank_end = 8'd51;
	vpos = 0;
	hpos = 0;
	lcd_xsize = 8'd160;
	lcd_ysize = 8'd160;
	frame_len = 20'd78719;
end

assign ce_pix = ce;

reg upper, vram_field;
wire vram_ce = vram_div == 5;
reg [3:0] vram_div;

reg [7:0] vb;
wire [7:0] vram_dout, buffer_dout;
wire [7:0] vram_din = ~vram_field ?
	{vb[7], vram_data[6], vb[5], vram_data[4], vb[3], vram_data[2], vb[1], vram_data[0]} :
	{vram_data[7], vb[6], vram_data[5], vb[4], vram_data[3], vb[2], vram_data[1], vb[0]} ;

dpram #(.addr_width(14)) vram_field_buf (
	.clock(clk),
	.address_a({~upper, vram_addr}),
	.data_a(vram_din),
	.q_a(vram_dout),
	.wren_a(vram_ce),

	.address_b({upper, video_addr}),
	.q_b(buffer_dout)
);

wire hblank_im = hpos <= hblank_end || hpos > hblank_end + lcd_xsize;
wire vblank_im = vpos < vblank_end || vpos >= vblank_end + lcd_ysize;
assign vsync = vpos < 2 || vpos > V_HEIGHT - 1'd1; // Catch the uneven line in vsync to see if it helps
assign hsync = hpos < 16 || hpos > (H_WIDTH - 8'd16);

assign vram_addr = (vpos_field_wrap * 8'h30) + (hpos_field_off);

always_ff @(posedge clk) begin
	if (ce) begin
		hblank <= hblank_im;
		vblank <= vblank_im;
		pixel <= lcd_off_latch ? 2'b00 : buffer_dout[{hpos_off[1:0], 1'b1}-:2];
		
		vram_div <= vram_div + 1'd1;
		if (vram_ce) begin
			vram_div <= 0;
			// FIXME: set address
			hpos_field <= hpos_field + 1'd1;
			if (hpos_field == 39) begin
				hpos_field <= 0;
				vpos_field <= vpos_field + 1'd1;
				if (vpos_field == 159)
					vpos_field <= 0;
			end
		end else begin
			vb <= vram_dout; // Buffer the vram data for muxxing with the current field.
		end
		


		if (lcd_off)
			lcd_off_latch <= 1;
		//pix_off <= {~hpos_off[1:0], 1'b1};
		dot_count <= dot_count + 1'd1;
		hpos <= hpos + 1'd1;
		if (hpos == (H_WIDTH - 1'd1)) begin
			hpos <= 0;
			vpos <= vpos + 1'd1;
		end
		if (dot_count == frame_len >> 1'd1)
			vram_field <= 1;

		// Synchronize with real frame, we'll see how it goes. This assumes 160x160.
		if (dot_count == frame_len) begin
			hpos <= 0;
			vpos <= 0;
			dot_count <= 0;
			hblank_end <= (H_WIDTH - lcd_xsize) >> 1'd1;
			vblank_end <= (V_HEIGHT - lcd_ysize) >> 1'd1;
			lcd_off_latch <= lcd_off;
			frame_len <= ((lcd_xsize[7:2] + 1'd1) * lcd_ysize * 12) - 1'd1;
			upper <= ~upper;
			vram_field <= 0;
			ybuff <= lcd_yscroll;
			xbuff <= lcd_xscroll;
		end
		
		if (lcd_cs && ~cpu_rwn) begin
			case(AB)
				6'h00, 6'h04: lcd_xsize <= dbus_in;
				6'h01, 6'h05: lcd_ysize <= dbus_in;
				6'h02, 6'h06: lcd_xscroll <= dbus_in;
				6'h03, 6'h07: lcd_yscroll <= dbus_in;
			endcase
		end
	end
	if (reset) begin
		lcd_xscroll <= 0;
		lcd_yscroll <= 0;
		hblank_end <= (H_WIDTH - lcd_xsize) >> 1'd1;
		vblank_end <= (V_HEIGHT - lcd_ysize) >> 1'd1;
		lcd_off_latch <= 1;
		// Do not reset these registers intentionally
		// lcd_xsize <= 8'd160;
		// lcd_ysize <= 8'd160;
	end
end

endmodule