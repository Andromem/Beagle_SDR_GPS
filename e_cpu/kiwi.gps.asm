
; ============================================================================
; Homemade GPS Receiver
; Copyright (C) 2013 Andrew Holme
;
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;
; http://www.holmea.demon.co.uk/GPS/Main.htm
; ============================================================================

; Copyright (c) 2014-2016 John Seamons, ZL/KF6VO


; ============================================================================
; GPS
; ============================================================================

				// UploadClock requires ch_NAV_MS and ch_NAV_BITS to be sequential
				
				STRUCT	GPS_CHAN
				 u16	ch_NAV_MS		1						; Milliseconds 0 ... 19
				 u16	ch_NAV_BITS		1						; Bit count
				 u16	ch_NAV_GLITCH	1						; Glitch count
				 u16	ch_NAV_PREV		1						; Last data bit = ip[15]
				 u16	ch_NAV_BUF		MAX_NAV_BITS / 16		; NAV data buffer
				 u64	ch_CG_FREQ		1						; Loop integrator
				 u64	ch_LO_FREQ		1						; Loop integrator
				 u32	ch_IQ			2						; Last IP, QP
				 u16	ch_CG_GAIN		2						; KI, KP-KI = 20, 27-20
				 u16	ch_LO_GAIN		2						; KI, KP-KI = 21, 28-21
				 u16	ch_unlocked		1
				ENDS

GPS_channels:	REPEAT	GPS_CHANS
				 GPS_CHAN	
				ENDR

GetGPSchanPtr:									; chan#
				push	sizeof GPS_CHAN			; chan# sizeof
				mult							; offset
				push	GPS_channels			; baseaddr
				add.r							; baseaddr + offset

; ============================================================================
;	err64 = conv64(pe-pl:32)
;	ki.e64 = err64 << (ki = ch_CG/LO_gain[0]:16)
;	new64 = (ch_CG/LO_FREQ:64) + ki.e64
;	(ch_CG/LO_FREQ:64) = new64
;	kp.e64 = ki.e64 << ("ki-kp" = ch_CG/LO_gain[1]:16)
;	nco64 = new64 + kp.e64
;	wrReg nco64:32
	
;	NB: fetch64 returns H L(tos)

				MACRO	CloseLoop freq gain nco
										; errH errL, i.e. pe-pl for CG loop, ip*qp for LO loop
				 r						; errH errL	this                1
				 addi	gain			; errH errL &gain[0]            1
				 fetch16				; errH errL ki                  1
				 shl64_n				; errH<<ki errL<<ki             ki+8
				 over					; ki.e64H L H                   1
				 over					; ki.e64H L H L                 1
				 r						; ki.e64H L H L this            1
				 addi	freq			; ki.e64H L H L &freq           1
				 fetch64				; ki.e64H L H L old64H L        19
				 add64					; ki.e64H L new64H L            7
				 over					; ki.e64H L new64H L H          1
				 over					; ki.e64H L new64H L H L        1
				 r						; ki.e64H L new64H L H L this   2
				 addi	freq			; ki.e64H L new64H L H L &freq  2
				 store64				; ki.e64H L new64H L &freq      17
				 pop					; ki.e64H L new64H L            1
				 swap64					; new64H L ki.e64H L            6
				 r						; new64H L ki.e64H L this       1
				 addi	gain + 2		; new64H L ki.e64H L &gain[1]   1
				 fetch16				; new64H L ki.e64H L kp-ki      1
				 shl64_n				; new64H L kp.e64H L            kp-ki+8
				 add64					; nco64H L                      7
				 pop					; nco32                         1
				 wrReg	nco				;                               1
				ENDM					;                 TOTAL = kp + 98
			
; ============================================================================

#if GPS_INTEG_BITS 16
// get 16-bit I/Q data
GetCount:		push	0						; 0								20
				rdBit							; [15]
GetCount2:
				REPEAT 15
				 rdBit							; 
				ENDR
				ret								; [15:0]

GetPower:		call	GetCount				; i								48
				dup
				mult							; i^2
				call	GetCount				; i^2 q
				dup
				mult							; i^2 q^2
				add.r							; p
#endif

#if GPS_INTEG_BITS 18
// get 18-bit I/Q data
GetCount:		push	0						; 0
				rdBit							; [17]
GetCount2:
				REPEAT 17
				 rdBit							; 
				ENDR
				ret								; [17:0]

GetPower:		call	GetCount				; i[17:0]
				dup                             ; i[17:0] i[17:0]
				mult18							; i^2[35:32] i^2[31:0]
				sext36_64                       ; i^2:H i^2:L
				call	GetCount				; i^2:H i^2:L q[17:0]
				dup                             ; i^2:H i^2:L q[17:0] q[17:0]
				mult18							; i^2:H i^2:L q^2[35:32] q^2[31:0]
				sext36_64                       ; ; i^2:H i^2:L q^2:H q^2:L
				add64							; pH pL
				ret                             ; pH pL

//CmdTestMult18:  rdReg	HOST_RX                 ; xa[15:0]
//                RdReg32 HOST_RX                 ; xa[15:0] xb[31:0]
CmdTestMult18:  push32  0x1 0xffff
                push32  0x1 0xffff
                mult18                          ; prod[35:32] prodWH|prodWL
                wrEvt	HOST_RST
                dup                             ; prod[35:32] prodWH|prodWL prodWH|prodWL
                wrReg	HOST_TX                 ; prod[35:32] prodWH|prodWL
                swap16                          ; prod[35:32] prodWL|prodWH
                wrReg	HOST_TX                 ; prod[35:32]
                wrReg	HOST_TX                 ;
                ret
#endif

; ============================================================================

sgn_pp_sub_pe:  u16     0

GPS_Method:									; this ch#
#if USE_LOGGER
                swap                        ; ch# this
                over                        ; ch# this ch#
				wrReg	SET_CHAN			; ch# this
                to_r						; ch#
                push    iq_ch               ; ch# &iq_ch
                fetch16                     ; ch# iq_ch
                sub                         ; (ch# == iq_ch)?
                brNZ    g_method_reg        ;               log only iq_ch channel

                rdReg	GET_CHAN_IQ			; 0
                rdBit						; Inav			keep msb of I as nav data
                dup							; Inav ip[MSB]
                call	GetCount2			; Inav ip
                swap16
                wrEvt   PUT_LOG             ;               save ip[31:16]
                swap16
                wrEvt   PUT_LOG             ;               save ip[15:0]
                call	GetCount   		    ; Inav ip qp
                swap16
                wrEvt   PUT_LOG             ;               save qp[31:16]
                swap16
                wrEvt   PUT_LOG             ;               save qp[15:0]
                
                br      g_continue          ; Inav ip qp
#endif
				wrReg	SET_CHAN			; this
                to_r						;

g_method_reg:
                rdReg	GET_CHAN_IQ			; 0
                rdBit						; Inav			keep msb of I as nav data
                dup							; Inav bit
                call	GetCount2			; Inav ip
                call	GetCount   		    ; Inav ip qp

g_continue:
				// save last I/Q values
				dup64						; Inav ip qp ip qp
				swap						; Inav ip ip qp ip
                r							; Inav ip qp qp ip this
                addi	ch_IQ 				; Inav ip qp qp ip &i
                store32						; Inav ip qp qp &i
                addi	4					; Inav ip qp qp &q
                store32						; Inav ip qp &q
                drop						; Inav ip qp

				// close the LO loop
				dup64						; Inav ip qp ip qp
#if GPS_INTEG_BITS 16
                mult						; Inav ip qp ip*qp
                conv32_64                   ; Inav ip qp ip*qp:H ip*qp:L
#else
                mult18						; Inav ip qp ip*qp[35:32] ip*qp[31:0]
                sext36_64                   ; Inav ip qp ip*qp:H ip*qp:L
#endif
                CloseLoop ch_LO_FREQ ch_LO_GAIN SET_LO_NCO

				// close the CG loop
#if GPS_INTEG_BITS 16
                dup							; Inav ip qp qp
                mult						; Inav ip qp^2
                swap						; Inav qp^2 ip
                dup							; Inav qp^2 ip ip
                mult						; Inav qp^2 ip^2
                add							; Inav pp
                call	GetPower			; Inav pp pe
                dup64						; Inav pp pe pp pe
                sub							; Inav pp pe pp-pe
                sgn32_16					; Inav pp pe (pp-pe)<0[15]
                rot							; Inav pe (pp-pe)<0 pp
                call	GetPower			; Inav pe (pp-pe)<0 pp pl
                swap						; Inav pe (pp-pe)<0 pl pp
                over						; Inav pe (pp-pe)<0 pl pp pl
                sub							; Inav pe (pp-pe)<0 pl pp-pl
                sgn32_16					; Inav pe (pp-pe)<0 pl (pp-pl)<0[15]
                rot							; Inav pe pl (pp-pl)<0 (pp-pe)<0
				or							; Inav pe pl unlocked:15
                r							; Inav pe pl unlocked this
                addi	ch_unlocked			; Inav pe pl unlocked &ch_unlocked
                store16						; Inav pe pl &ch_unlocked
                pop							; Inav pe pl
                sub							; Inav pe-pl
                conv32_64                   ; Inav pe-pl:H L
#else
                dup							; Inav ip qp qp
                mult18						; Inav ip qp^2H qp^2L
                sext36_64
                rot                         ; Inav qp^2H qp^2L ip
                dup							; Inav qp^2H qp^2L ip ip
                mult18						; Inav qp^2H qp^2L ip^2H ip^2L
                sext36_64
                add64                       ; Inav ppH L
                call	GetPower			; Inav ppH L peH L
                over64						; Inav ppH L peH L ppH L
                over64						; Inav ppH L peH L ppH L peH L
                sub64						; Inav ppH L peH L pp-pe:H L
                sgn64_16					; Inav ppH L peH L (pp-pe)<0[15]
                to_r                        ; Inav ppH L peH L                  ; (pp-pe)<0[15]
                swap64						; Inav peH L ppH L
                call	GetPower			; Inav peH L ppH L plH L
                swap64						; Inav peH L plH L ppH L
                over64						; Inav peH L plH L ppH L plH L
                sub64						; Inav peH L plH L pp-pl:H L
                sgn64_16					; Inav peH L plH L (pp-pl)<0[15]
                r_from                      ; Inav peH L plH L (pp-pl)<0[15] (pp-pe)<0[15]
				or							; Inav peH L plH L unlocked[15]
                r							; Inav peH L plH L unlocked this
                addi	ch_unlocked			; Inav peH L plH L unlocked &ch_unlocked
                store16						; Inav peH L plH L &ch_unlocked
                pop							; Inav peH L plH L
                sub64						; Inav pe-pl:H L
#endif
                CloseLoop ch_CG_FREQ ch_CG_GAIN SET_CG_NCO


				// process NAV data (20 msec per bit @ 50 bps)
				// remember: loop is running at 1 kHz (1 msec), so 20 samples per bit
				
				//	if (Inav == ch_NAV_PREV) {
				//		// NavSame
				//		if (ch_NAV_MS != 19) ch_NAV_MS++, return
				//		
				//		stayed same for all 20 samples
				//		ch_NAV_MS = 0
				//		ch_NAV_BITS = (ch_NAV_BITS + 1) & (MAX_NAV_BITS - 1)
				//		ch_NAV_BUF[] <<= |= Inav
				//		return
				//	}
				//	
				//	ch_NAV_PREV = Inav
				//	
				//	if (ch_NAV_MS != 0) ch_NAV_GLITCH++		// changed in the middle of sampling
				//	
				//	// NavEdge
				//	ch_NAV_MS = 1
				//	return


				// if Inav == ch_NAV_PREV goto NavSame
                r							; Inav this
                addi	ch_NAV_PREV			; Inav &prev
                fetch16						; Inav prev
                over						; Inav prev Inav
                sub							; Inav diff
                brZ		NavSame				; Inav

                r							; Inav this
                addi	ch_NAV_PREV			; Inav &prev
                store16
                drop						;
                
				// if ch_NAV_MS == 0 then goto NavEdge
                r							; this
                addi	ch_NAV_MS			; &ms
                fetch16						; ms
                brZ		NavEdge

				// ch_NAV_GLITCH++
                r							; this
                addi	ch_NAV_GLITCH		; &g
                fetch16						; g
                addi	1					; g+1
                r							; g+1 this
                addi	ch_NAV_GLITCH		; g+1 &g
                store16
                drop						;

NavEdge:        // ch_NAV_MS = 1
				push	1					; 1
                r_from						; 1 this
                addi	ch_NAV_MS			; 1 &ms
                store16
                drop.r						;

NavSame:        // if ch_NAV_MS == 19 then goto NavSave
				r							; Inav this
                addi	ch_NAV_MS			; Inav &ms
                dup							; Inav &ms &ms
                fetch16						; Inav &ms ms
                push	19
                sub							; Inav &ms ms-19
                brZ		NavSave				; Inav &ms

				// else ch_NAV_MS++
                fetch16						; Inav ms
                addi	1					; Inav ms+1
                r_from						; Inav ms+1 this
                addi	ch_NAV_MS			; Inav ms+1 &ms
                store16
                drop						; Inav
                drop.r						;

NavSave:        // ch_NAV_MS = 0
				push	0
				swap						; Inav 0 &ms
                store16
                drop						; Inav
                
				// ch_NAV_BITS = (ch_NAV_BITS + 1) & (MAX_NAV_BITS - 1)
                r							; Inav this
                addi	ch_NAV_BITS			; Inav &cnt
                fetch16						; Inav cnt
                dup							; Inav cnt cnt
                addi	1					; Inav cnt cnt+1
                push	MAX_NAV_BITS - 1
                and							; Inav cnt wrapped
                r							; Inav cnt wrapped this
                addi	ch_NAV_BITS			; Inav cnt wrapped &cnt
                store16
                drop						; Inav cnt

				// ch_NAV_BUF[] <<= |= Inav
				REPEAT	4
				 shr						; Inav cnt/16
				ENDR
                shl							; Inav offset
                r_from						; Inav offset this
                addi	ch_NAV_BUF			; Inav offset buf
                add							; Inav ptr
                dup							; Inav ptr ptr
                to_r						; Inav ptr
                fetch16						; Inav old
                shl							; Inav old<<1
                add							; new
                r_from						; new ptr
                store16
                drop.r						;
			
; ============================================================================

UploadChan:										; &GPS_channels[n]
				REPEAT	sizeof GPS_CHAN / 2
				 wrEvt	GET_MEMORY
				ENDR
				ret

// "wrEvt GET_MEMORY" side-effect: auto mem ptr incr, i.e. 2x tos += 2 (explains "-4" below)
UploadClock:									; &GPS_channels
				wrEvt	GET_MEMORY				; GPS_channels++ -> ch_NAV_MS
				wrEvt	GET_MEMORY				; GPS_channels++ -> ch_NAV_BITS

#if GPS_REPL_BITS 16
				rdBit16							; 16-bit clock replica
				wrReg	HOST_TX
#endif

#if GPS_REPL_BITS 18
				rdBit16							; 18-bit clock replica sent across 2 words
				wrReg	HOST_TX
				push    0
				rdBit
				rdBit
				wrReg	HOST_TX
#endif
				addi.r	sizeof GPS_CHAN - 4		; &GPS_channels++

UploadGlitches:									; &GPS_channels + ch_NAV_GLITCH
				wrEvt	GET_MEMORY
				addi.r	sizeof GPS_CHAN - 2		; &(GPS_channels+1) + ch_NAV_GLITCH

; ============================================================================

				MACRO	SetRate member nco		;
				 rdReg	HOST_RX					; chan
				 RdReg32 HOST_RX				; chan freq32
				 swap							; freq32 chan
				 over							; freq32 chan freq32
				 over							; freq32 chan freq32 chan
				 call	GetGPSchanPtr			; freq32 chan freq32 this
				 addi	member					; freq32 chan freq32 &freq
				 push	0						; freq32 chan freq32 &freq 0
				 swap							; freq32 chan freq64 &freq
				 store64						; freq chan &freq
				 drop							; freq chan
				 wrReg	SET_CHAN				; freq
				 wrReg	nco						;
				ENDM

				MACRO	SetGain member			;
				 rdReg	HOST_RX					; chan
				 RdReg32 HOST_RX				; chan kp,ki
				 swap							; kp,ki chan
				 call	GetGPSchanPtr			; kp,ki this
				 addi	member					; kp,ki &gain
				 store32						; &gain
				 drop							;
				ENDM

; ============================================================================

CmdSample:		wrEvt	GPS_SAMPLER_RST
            	ret

CmdSetMask:     SetReg	SET_MASK
                ret

CmdSetRateCG:   SetRate	ch_CG_FREQ SET_CG_NCO
                ret

CmdSetRateLO:   SetRate	ch_LO_FREQ SET_LO_NCO
                ret

CmdSetGainCG:   SetGain ch_CG_GAIN
                ret

CmdSetGainLO:   SetGain ch_LO_GAIN
                ret

CmdSetSat:      SetReg	SET_CHAN
                SetReg	SET_SAT
                ret

CmdWRstE1Bcode: SetReg	SET_CHAN
                wrEvt   WRST_E1B_CODE
                ret

CmdSetE1Bcode:  SetReg	SET_CHAN
                SetReg	SET_E1B_CODE
                ret

CmdPause:       SetReg	SET_CHAN
                SetReg	SET_PAUSE
                ret

CmdGetGPSSamples:
				wrEvt	HOST_RST
				push	GPS_SAMPS
up_more:
				wrEvt	GET_GPS_SAMPLES
				push	1
				sub
				dup
				brNZ	up_more
				drop.r

CmdGetChan:     rdReg	HOST_RX				; chan#
                wrEvt	HOST_RST			; chan#
                call	GetGPSchanPtr		; this
                call	UploadChan			; this++
                drop.r

CmdGetClocks:   wrEvt	HOST_RST
                rdReg	GET_SNAPSHOT		; 0
                rdBit16z					; 48-bit system clock
                wrReg	HOST_TX
                rdBit16						; "
                wrReg	HOST_TX
                rdBit16						; "
                wrReg	HOST_TX
                
                push	0
                REPEAT	GPS_CHANS
                 rdBit						; chan srq
                ENDR
                wrReg	HOST_TX
                
                push	GPS_channels + ch_NAV_MS
                REPEAT	GPS_CHANS
                 call	UploadClock
                ENDR
                drop.r

CmdGetGlitches: wrEvt	HOST_RST
                push	GPS_channels + ch_NAV_GLITCH
                REPEAT	GPS_CHANS
                 call	UploadGlitches
                ENDR
                drop.r

iq_ch:			u16		0

CmdIQLogReset:  rdReg	HOST_RX             ; ch#
                push    iq_ch               ; ch# &iq_ch
                store16                     ; &iq_ch
				wrEvt	LOG_RST             ; &iq_ch
                pop.r                       ;

CmdIQLogGet:    wrEvt	HOST_RST
				push	GPS_IQ_SAMPS
up_more_log:
				wrEvt	GET_LOG             ; IH
				wrEvt	GET_LOG             ; IL
				wrEvt	GET_LOG             ; QH
				wrEvt	GET_LOG             ; QL
				push	1
				sub
				dup
				brNZ	up_more_log
				drop.r
