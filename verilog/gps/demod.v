//////////////////////////////////////////////////////////////////////////
// Homemade GPS Receiver
// Copyright (C) 2013 Andrew Holme
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// http://www.holmea.demon.co.uk/GPS/Main.htm
//////////////////////////////////////////////////////////////////////////

`default_nettype none

module DEMOD (
    input  wire        clk,
    input  wire        rst,
    input  wire        sample,
    input  wire        cg_resume, 
    input  wire        wrReg,
    input  wire [15:0] op,
    input  wire [31:0] tos,
    input  wire        shift,
    
    output reg [E1B_CODEBITS-1:0]  nchip,
    input  wire        e1b_code,
    
    output wire        sout,
    output reg         ms0,
    output wire [GPS_REPL_BITS-1:0] replica
);

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Select sat

    reg e1b_mode, g2_init;
    reg [10:1] init;

    always @ (posedge clk)
        if (wrReg && op[SET_SAT]) begin
            {e1b_mode, g2_init, init} <= tos[11:0];
        end

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Pause code generator (to align with sat)

    reg cg_en;

    always @ (posedge clk)
        if (wrReg && op[SET_PAUSE])
            cg_en <= 0;
        else if (~cg_en)
            cg_en <= cg_resume;

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // NCOs

    reg  [31:0] lo_rate = 0;
    wire [31:0] lo_phase;

    reg  [31:0] cg_rate = 0, cg_phase = 0;
    wire [31:0] cg_sum;

    wire full_chip;
    wire half_chip;
    wire quarter_chip;
    wire full_chip_en = full_chip & cg_en;
    
    ip_add_u30b cg_nco (.a(cg_phase[29:0]), .b(cg_rate[29:0]), .s({quarter_chip, cg_sum[29:0]}), .c_in(1'b0));
    
    wire a30 = cg_phase[30];
    wire b30 = cg_rate[30];
    wire ci30 = quarter_chip;
    
	wire d30 = a30 ^ b30;
	XORCY xorcy30 (         .LI(d30), .CI(ci30), .O(cg_sum[30]));	
	MUXCY muxcy30 (.S(d30), .DI(a30), .CI(ci30), .O(half_chip));

    wire a31 = cg_phase[31];
    wire b31 = cg_rate[31];
    wire ci31 = half_chip;
    
	wire d31 = a31 ^ b31;
	XORCY xorcy31 (         .LI(d31), .CI(ci31), .O(cg_sum[31]));	
	MUXCY muxcy31 (.S(d31), .DI(a31), .CI(ci31), .O(full_chip));

	ip_acc_u32b lo_nco (.clk(clk), .sclr(1'b0), .b(lo_rate), .q(lo_phase));

    always @ (posedge clk) begin
        if (wrReg && op[SET_LO_NCO]) lo_rate <= tos;
        if (wrReg && op[SET_CG_NCO]) cg_rate <= tos;
        if (rst) cg_phase <= 0; else if (cg_en) cg_phase <= cg_sum;
    end

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // code generators

    reg  [E1B_CODEBITS-1:0] chips;
    reg         cg_p, ms1, cg_l = 0;

    always @ (posedge clk)
        ms1 <= ms0;
        
    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // C/A, E1B code and epoch

    wire ca_chip;
    
    // FIXME: is boc11 not really necessary?
    //wire boc11 = cg_phase[31];  // bit that toggles at the half-chip rate
    //wire e1b_chip = e1b_code ^ boc11;
    wire e1b_chip = e1b_code;

    wire cg_e = e1b_mode? e1b_chip : ca_chip;

    reg quarter_after_full;

    always @ (posedge clk) begin
        if (rst)
            nchip <= 0;
        else
        
        if (e1b_mode) begin
            if (full_chip_en)
                nchip <= (nchip == (E1B_CODELEN-1))? 0 : (nchip+1);

            if (full_chip)
                quarter_after_full <= 1;
            
            if (quarter_chip) begin
                if (!full_chip) begin
                    if (quarter_after_full && !half_chip) begin
                        cg_p <= cg_e;
                        chips <= nchip;         // for replica
                        ms0 <= (nchip == 0);    // Epoch
                        quarter_after_full <= 0;
                    end
                    
                    if (half_chip)
                        cg_l <= cg_p;
                end
            end
            else
                ms0 <= 0;
        end
        else begin
            if (full_chip_en)
                nchip <= (nchip == (L1_CODELEN-1))? 0 : (nchip+1);
                
            if (half_chip)
                if (full_chip)
                    cg_l <= cg_p;
                else begin
                    cg_p <= cg_e;
                    chips <= nchip;         // for replica
                    ms0 <= (nchip == 0);    // Epoch
                end
            else
                ms0 <= 0;
        end
    end

    wire ca_rd = full_chip_en;
    CACODE ca (.rst(rst), .clk(clk), .g2_init(g2_init), .init(init), .rd(ca_rd), .chip(ca_chip));

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Quadrature final LO

    wire [3:0] lo_sin = 4'b1100;
    wire [3:0] lo_cos = 4'b0110;

    wire LO_I = lo_sin[lo_phase[31:30]];
    wire LO_Q = lo_cos[lo_phase[31:30]];

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Down-convert to baseband

    reg lsb, die, dqe, dip, dqp, dil, dql;
    // register length chosen to not overflow with our 16.368 MHz GPS clock and code length
    reg [GPS_INTEG_BITS:1] ie, qe, ip, qp, il, ql;

    always @ (posedge clk) begin

        // Mixers
        die <= sample^cg_e^LO_I; dqe <= sample^cg_e^LO_Q;
        dip <= sample^cg_p^LO_I; dqp <= sample^cg_p^LO_Q;
        dil <= sample^cg_l^LO_I; dql <= sample^cg_l^LO_Q;

        // Filters 
        ie <= (ms1? {GPS_INTEG_BITS{1'b0}} : ie) + {GPS_INTEG_BITS{die}} + lsb;
        qe <= (ms1? {GPS_INTEG_BITS{1'b0}} : qe) + {GPS_INTEG_BITS{dqe}} + lsb;
        ip <= (ms1? {GPS_INTEG_BITS{1'b0}} : ip) + {GPS_INTEG_BITS{dip}} + lsb;
        qp <= (ms1? {GPS_INTEG_BITS{1'b0}} : qp) + {GPS_INTEG_BITS{dqp}} + lsb;
        il <= (ms1? {GPS_INTEG_BITS{1'b0}} : il) + {GPS_INTEG_BITS{dil}} + lsb;
        ql <= (ms1? {GPS_INTEG_BITS{1'b0}} : ql) + {GPS_INTEG_BITS{dql}} + lsb;

        lsb <= ms1? 1'b0 : ~lsb; 

    end

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Serial output of IQ accumulators to embedded CPU

    localparam SER_IQ_MSB = (6 * GPS_INTEG_BITS) - 1;
    
    reg [SER_IQ_MSB:0] ser_iq;

    always @ (posedge clk)
        if (ms1)
            ser_iq <= {ip, qp, ie, qe, il, ql};
       else if (shift)
          ser_iq <= ser_iq << 1;

    assign sout = ser_iq[SER_IQ_MSB];

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Clock replica

    generate
        if (GPS_REPL_BITS == 16) begin
            assign replica = {~cg_phase[31], cg_phase[30:26], chips[9:0]};
        end

        if (GPS_REPL_BITS == 18) begin
            assign replica = {~cg_phase[31], cg_phase[30:26], chips[9:0], chips[11:10]};
        end
    endgenerate

endmodule
