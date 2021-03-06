//----------------------------------------------------------------------------
//
//  Arcade: Mario Bros by gaz68 (https://github.com/gaz68)
//
//  June 2020
//
//  Based on the original Donkey Kong core by Katsumi Degawa.
//
//  Original Donkey Kong port to MiSTer
//  Copyright (C) 2017 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//----------------------------------------------------------------------------

module emu
(
  //Master input clock
  input         CLK_50M,

  //Async reset from top-level module.
  //Can be used as initial reset.
  input         RESET,

  //Must be passed to hps_io module
  inout  [45:0] HPS_BUS,

  //Base video clock. Usually equals to CLK_SYS.
  output        CLK_VIDEO,

  //Multiple resolutions are supported using different CE_PIXEL rates.
  //Must be based on CLK_VIDEO
  output        CE_PIXEL,

  //Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
  output  [7:0] VIDEO_ARX,
  output  [7:0] VIDEO_ARY,

  output  [7:0] VGA_R,
  output  [7:0] VGA_G,
  output  [7:0] VGA_B,
  output        VGA_HS,
  output        VGA_VS,
  output        VGA_DE,    // = ~(VBlank | HBlank)
  output        VGA_F1,
  output [1:0]  VGA_SL,

  // Use framebuffer from DDRAM (USE_FB=1 in qsf)
  // FB_FORMAT:
  //    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
  //    [3]   : 0=16bits 565 1=16bits 1555
  //    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
  //
  // stride is modulo 256 of bytes

  output        FB_EN,
  output  [4:0] FB_FORMAT,
  output [11:0] FB_WIDTH,
  output [11:0] FB_HEIGHT,
  output [31:0] FB_BASE,
  input         FB_VBL,
  input         FB_LL,

  output        LED_USER,  // 1 - ON, 0 - OFF.

  // b[1]: 0 - LED status is system status OR'd with b[0]
  //       1 - LED status is controled solely by b[0]
  // hint: supply 2'b00 to let the system control the LED.
  output  [1:0] LED_POWER,
  output  [1:0] LED_DISK,

  input         CLK_AUDIO, // 24.576 MHz
  output [15:0] AUDIO_L,
  output [15:0] AUDIO_R,
  output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned

  //High latency DDR3 RAM interface
  //Use for non-critical time purposes
  output        DDRAM_CLK,
  input         DDRAM_BUSY,
  output  [7:0] DDRAM_BURSTCNT,
  output [28:0] DDRAM_ADDR,
  input  [63:0] DDRAM_DOUT,
  input         DDRAM_DOUT_READY,
  output        DDRAM_RD,
  output [63:0] DDRAM_DIN,
  output  [7:0] DDRAM_BE,
  output        DDRAM_WE,

  // Open-drain User port.
  // 0 - D+/RX
  // 1 - D-/TX
  // 2..6 - USR2..USR6
  // Set USER_OUT to 1 to read from USER_IN.
  input   [6:0] USER_IN,
  output  [6:0] USER_OUT
);

assign VGA_F1 = 0;
assign USER_OUT  = '1;
assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;

assign VIDEO_ARX = status[1] ? 8'd16 : status[2] ? 8'd3 : 8'd4;
assign VIDEO_ARY = status[1] ? 8'd9  : status[2] ? 8'd4 : 8'd3;

`include "build_id.v" 
localparam CONF_STR = {
   "A.MARIO;;",
   "-;",
   "O1,Aspect Ratio,Original,Wide;",
   "O2,Orientation,Horz,Vert;",
   "O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
   "ODG,Analogue Sound Vol,100%,Off,10%,20%,30%,40%,50%,60%,70%,80%,90%,;",
   "-;",
   "DIP;",
   //"O89,Lives,3,4,5,6;",
   //"OAB,Coin/Credit,1/1,2/1,1/2,1/3;",
   //"OCD,Extra Life,20000,30000,40000,None;",
   //"OEF,Difficulty,Easy,Medium,Hard,Hardest;",
   "-;",

   "R0,Reset;",
   "J1,Jump,Start 1P,Start 2P;",
   "jn,A,Start,Select,R;",
   "V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;
wire clk_sub;
wire clk_main;

pll pll
(
   .refclk(CLK_50M),
   .rst(0),
   .outclk_0(clk_sys),  // 24 Mhz
   .outclk_1(clk_sub),  // 11 Mhz
   .outclk_2(clk_main)  //  4 Mhz
);

///////////////////////////////////////////////////

wire [31:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        direct_video;

wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;

wire [10:0] ps2_key;

wire [15:0] joy_0, joy_1;
wire [21:0] gamma_bus;

hps_io #(.STRLEN($size(CONF_STR)>>3)) hps_io
(
   .clk_sys(clk_sys),
   .HPS_BUS(HPS_BUS),
   .EXT_BUS(),
   
   .conf_str(CONF_STR),

   .buttons(buttons),
   .status(status),
   .forced_scandoubler(forced_scandoubler),
   .gamma_bus(gamma_bus),
   .direct_video(direct_video),
   .status_menumask(direct_video),

   .ioctl_download(ioctl_download),
   .ioctl_wr(ioctl_wr),
   .ioctl_addr(ioctl_addr),
   .ioctl_dout(ioctl_dout),
   .ioctl_index(ioctl_index),

   .joystick_0(joy_0),
   .joystick_1(joy_1),
   .ps2_key(ps2_key)
);

wire       pressed = ps2_key[9];
wire [8:0] code    = ps2_key[8:0];
always @(posedge clk_sys) begin
   reg old_state;
   old_state <= ps2_key[10];

   if(old_state != ps2_key[10]) begin
      casex(code)
         'hX6B: btn_left        <= pressed; // left
         'hX74: btn_right       <= pressed; // right
         'h029: btn_fire        <= pressed; // space
         'h014: btn_fire        <= pressed; // ctrl

         // JPAC/IPAC/MAME Style Codes

         'h005: btn_one_player  <= pressed; // F1
         'h006: btn_two_players <= pressed; // F2
         'h016: btn_start_1     <= pressed; // 1
         'h01E: btn_start_2     <= pressed; // 2
         'h02E: btn_coin_1      <= pressed; // 5
         'h036: btn_coin_2      <= pressed; // 6
         'h023: btn_left_2      <= pressed; // D
         'h034: btn_right_2     <= pressed; // G
         'h01C: btn_fire_2      <= pressed; // A
         'h02C: btn_test        <= pressed; // T
      endcase
   end
end

reg btn_right = 0;
reg btn_left  = 0;
reg btn_fire  = 0;
reg btn_one_player  = 0;
reg btn_two_players = 0;

reg btn_start_1 = 0;
reg btn_start_2 = 0;
reg btn_coin_1  = 0;
reg btn_coin_2  = 0;

reg btn_left_2  = 0;
reg btn_right_2 = 0;
reg btn_fire_2  = 0;
reg btn_test    = 0;

wire m_left,m_right;
joy2way joy1
(
   clk_sys,
   {
      btn_left  | joy_0[1],
      btn_right | joy_0[0]
   },
   {m_left,m_right}
);

wire m_left_2,m_right_2;
joy2way joy2
(
   clk_sys,
   {
      btn_left_2  | joy_1[1],
      btn_right_2 | joy_1[0]
   },
   {m_left_2,m_right_2}
);

wire m_fire   = btn_fire | joy_0[4];
wire m_fire_2 = btn_fire_2 | joy_1[4];

wire m_start1 = btn_one_player  | joy_0[5] | joy_1[5];
wire m_start2 = btn_two_players | joy_0[6] | joy_1[6];
wire m_coin   = joy_0[7] | joy_1[7];

//wire [7:0]m_dip = status[15:8];
reg [7:0] sw[8];
always @(posedge clk_sys) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

wire [7:0]m_sw1={~btn_test,~{m_start2|btn_start_2},~{m_start1|btn_start_1},~m_fire,1'b1,1'b1,~m_left,~m_right};
wire [7:0]m_sw2={1'b1,1'b1,~{m_coin|btn_coin_1|btn_coin_2},~m_fire_2,1'b1,1'b1,~m_left_2,~m_right_2};

wire hblank, vblank;
wire hs, vs;
wire [2:0] r,g;
wire [1:0] b;

wire rotate_ccw = 1;
wire no_rotate = ~status[2] | direct_video  ;
screen_rotate screen_rotate (.*);

arcade_video#(256,8) arcade_video
(
   .*,

   .clk_video(clk_sys),
   .ce_pix(ce_vid),

   .RGB_in({r,g,b}),
   .HBlank(hblank),
   .VBlank(vblank),
   .HSync(~hs),
   .VSync(~vs),

   .fx(status[5:3])
);

assign hblank = hbl[8];

reg  ce_vid;
wire clk_pix;
wire hbl0;
reg [8:0] hbl;
always @(posedge clk_sys) begin
   reg old_pix;
   old_pix <= clk_pix;
   ce_vid <= 0;
   if(~old_pix & clk_pix) begin
      ce_vid <= 1;
      hbl <= (hbl<<1)|hbl0;
   end
end

wire signed [15:0] audio;
assign AUDIO_L   = audio;
assign AUDIO_R   = audio;
assign AUDIO_S   = 1'b1;

mario_top mariobros 
(
   .I_CLK_24M(clk_sys),
   .I_CLK_4M(clk_main),
   .I_CLK_11M(clk_sub),
   .I_RESETn(~(RESET | status[0] | buttons[1])),

   .dn_addr(ioctl_addr),
   .dn_data(ioctl_dout),
   .dn_wr(ioctl_wr && ioctl_index==0),

   .O_PIX(clk_pix),

   .I_SW1(m_sw1),
   .I_SW2(m_sw2),
   .I_DIPSW(sw[0]),
   //.I_DIPSW(m_dip),
   .I_ANLG_VOL(status[16:13]),

   .O_VGA_R(r),
   .O_VGA_G(g),
   .O_VGA_B(b),
   .O_VGA_HSYNCn(hs),
   .O_VGA_VSYNCn(vs),
   .O_HBLANK(hbl0),
   .O_VBLANK(vblank),

   .O_SOUND_DAT(audio)
);

endmodule

// Handle the case where Left and Right are pressed simultaneously
// i.e. when using a keyboard.
module joy2way
(
   input        clk,
   input  [1:0] indir,
   output [1:0] outdir
);

reg   [1:0] out = 0;
reg   [1:0] in1,in2;
wire  [1:0] innew = in1 & ~in2;
reg   [1:0] last_h;

assign outdir = out;

always @(posedge clk) begin

   in1 <= indir;
   in2 <= in1;

   if(innew[0]) last_h <= 2'b01; // R
   if(innew[1]) last_h <= 2'b10; // L

   out <= in1 == 2'b11 ? last_h : in1; 
end

endmodule
