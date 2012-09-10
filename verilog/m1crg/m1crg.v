module m1crg #(
	parameter in_period = 0.0,
	parameter f_mult = 0,
	parameter f_div = 0,
	parameter clk2x_period = (in_period*f_div)/(2.0*f_mult)
) (
	input clkin,
	input trigger_reset,
	
	output sys_clk,
	output reg sys_rst,
	
	/* Reset off-chip devices */
	output ac97_rst_n,
	output videoin_rst_n,
	output flash_rst_n,
	
	/* DDR PHY clocks */
	output clk2x_270,
	output clk4x_wr,
	output clk4x_wr_strb,
	output clk4x_rd,
	output clk4x_rd_strb,
	
	/* Ethernet PHY clock */
	output reg eth_clk_pad,	/* < unbuffered, to I/O */
	
	/* VGA clock */
	output vga_clk,		/* < buffered, to internal clock network */
	output vga_clk_pad	/* < forwarded through ODDR2, to I/O */
);

/*
 * Reset
 */

reg [19:0] rst_debounce;
always @(posedge sys_clk) begin
	if(trigger_reset)
		rst_debounce <= 20'hFFFFF;
	else if(rst_debounce != 20'd0)
		rst_debounce <= rst_debounce - 20'd1;
	sys_rst <= rst_debounce != 20'd0;
end

assign ac97_rst_n = ~sys_rst;
assign videoin_rst_n = ~sys_rst;

/*
 * We must release the Flash reset before the system reset
 * because the Flash needs some time to come out of reset
 * and the CPU begins fetching instructions from it
 * as soon as the system reset is released.
 * From datasheet, minimum reset pulse width is 100ns
 * and reset-to-read time is 150ns.
 */

reg [7:0] flash_rstcounter;

always @(posedge sys_clk) begin
	if(trigger_reset)
		flash_rstcounter <= 8'd0;
	else if(~flash_rstcounter[7])
		flash_rstcounter <= flash_rstcounter + 8'd1;
end

assign flash_rst_n = flash_rstcounter[7];

/*
 * Clock management. Inspired by the NWL reference design.
 */

wire sdr_clkin;
wire clkdiv;

IBUF #(
	.IOSTANDARD("DEFAULT")
) clk2_iob (
	.I(clkin),
	.O(sdr_clkin)
);

BUFIO2 #(
	.DIVIDE(1),
	.DIVIDE_BYPASS("FALSE"),
	.I_INVERT("FALSE")
) bufio2_inst2 (
	.I(sdr_clkin),
	.IOCLK(),
	.DIVCLK(clkdiv),
	.SERDESSTROBE()
);

wire pll_lckd;
wire buf_pll_fb_out;
wire pllout0;
wire pllout1;
wire pllout2;
wire pllout3;
wire pllout4;

PLL_ADV #(
	.BANDWIDTH("OPTIMIZED"),
	.CLKFBOUT_MULT(4*f_mult),
	.CLKFBOUT_PHASE(0.0),
	.CLKIN1_PERIOD(in_period),
	.CLKIN2_PERIOD(in_period),
	.CLKOUT0_DIVIDE(f_div),
	.CLKOUT0_DUTY_CYCLE(0.5),
	.CLKOUT0_PHASE(0),
	.CLKOUT1_DIVIDE(f_div),
	.CLKOUT1_DUTY_CYCLE(0.5),
	.CLKOUT1_PHASE(0),
	.CLKOUT2_DIVIDE(2*f_div),
	.CLKOUT2_DUTY_CYCLE(0.5),
	.CLKOUT2_PHASE(270.0),
	.CLKOUT3_DIVIDE(4*f_div),
	.CLKOUT3_DUTY_CYCLE(0.5),
	.CLKOUT3_PHASE(0.0),
	.CLKOUT4_DIVIDE(4*f_mult),
	.CLKOUT4_DUTY_CYCLE(0.5),
	.CLKOUT4_PHASE(0),
	.CLKOUT5_DIVIDE(7),
	.CLKOUT5_DUTY_CYCLE(0.5),
	.CLKOUT5_PHASE(0.0),
	.COMPENSATION("INTERNAL"),
	.DIVCLK_DIVIDE(1),
	.REF_JITTER(0.100),
	.CLK_FEEDBACK("CLKFBOUT"),
	.SIM_DEVICE("SPARTAN6")
) pll (
	.CLKFBDCM(),
	.CLKFBOUT(buf_pll_fb_out),
	.CLKOUT0(pllout0), /* < x4 clock for writes */
	.CLKOUT1(pllout1), /* < x4 clock for reads */
	.CLKOUT2(pllout2), /* < x2 90 clock to generate memory clock, clock DQS and memory address and control signals. */
	.CLKOUT3(pllout3), /* < x1 clock for system and memory controller */
	.CLKOUT4(pllout4), /* < buffered clkin */
	.CLKOUT5(),
	.CLKOUTDCM0(),
	.CLKOUTDCM1(),
	.CLKOUTDCM2(),
	.CLKOUTDCM3(),
	.CLKOUTDCM4(),
	.CLKOUTDCM5(),
	.DO(),
	.DRDY(),
	.LOCKED(pll_lckd),
	.CLKFBIN(buf_pll_fb_out),
	.CLKIN1(clkdiv),
	.CLKIN2(1'b0),
	.CLKINSEL(1'b1),
	.DADDR(5'b00000),
	.DCLK(1'b0),
	.DEN(1'b0),
	.DI(16'h0000),
	.DWE(1'b0),
	.RST(1'b0),
	.REL(1'b0)
);

BUFPLL #(
	.DIVIDE(4)
) wr_bufpll (
	.PLLIN(pllout0),
	.GCLK(sys_clk),
	.LOCKED(pll_lckd),
	.IOCLK(clk4x_wr),
	.LOCK(),
	.SERDESSTROBE(clk4x_wr_strb)
);

BUFPLL #(
	.DIVIDE(4)
) rd_bufpll (
	.PLLIN(pllout1),
	.GCLK(sys_clk),
	.LOCKED(pll_lckd),
	.IOCLK(clk4x_rd),
	.LOCK(),
	.SERDESSTROBE(clk4x_rd_strb)
);

BUFG bufg_x2_2(
	.I(pllout2),
	.O(clk2x_270)
);

BUFG bufg_x1(
	.I(pllout3),
	.O(sys_clk)
);

/* Ethernet PHY */
always @(posedge pllout4)
	eth_clk_pad <= ~eth_clk_pad;

/* VGA clock */
// TODO: hook up the reprogramming interface
DCM_CLKGEN #(
	.CLKFXDV_DIVIDE(2),
	.CLKFX_DIVIDE(4),
	.CLKFX_MD_MAX(2.0),
	.CLKFX_MULTIPLY(2),
	.CLKIN_PERIOD(0.0),
	.SPREAD_SPECTRUM("NONE"),
	.STARTUP_WAIT("FALSE")
) vga_clock_gen (
	.CLKFX(vga_clk),
	.CLKFX180(),
	.CLKFXDV(),
	.LOCKED(),
	.PROGDONE(),
	.STATUS(),
	.CLKIN(pllout4),
	.FREEZEDCM(1'b0),
	.PROGCLK(1'b0),
	.PROGDATA(),
	.PROGEN(1'b0),
	.RST(1'b0)
);

ODDR2 #(
	.DDR_ALIGNMENT("NONE"),
	.INIT(1'b0),
	.SRTYPE("SYNC")
) vga_clock_forward (
	.Q(vga_clk_pad),
	.C0(vga_clk),
	.C1(~vga_clk),
	.CE(1'b1),
	.D0(1'b1),
	.D1(1'b0),
	.R(1'b0),
	.S(1'b0)
);
 
endmodule
