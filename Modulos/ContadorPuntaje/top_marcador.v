/*
 * Sistema Sumador de puntos
 *
 * FPGA: Cyclone IV EP4CE10E22C8 (reloj de 50 MHz)
 *
 *
 */

// ==========================================
// 1. MÓDULO TOP
// ==========================================
module top_marcador #(
    parameter CLK_HZ                = 50_000_000, // Reloj de la placa
    parameter CAMBIO_HZ             = 4_000,      // Cambios de display por segundo (1 kHz por display)
    parameter ENTRADAS_ACTIVAS_BAJO = 1,          // 1: switch/botón en "bajo" = 0 lógico (entradas con pull-up)
    parameter SEG_ACTIVOS_BAJO      = 1,          // 1: ánodo común (segmento enciende con 0)
    parameter DIG_ACTIVOS_BAJO      = 1,          // 1: selección de display activa en 0
    parameter RESET_ACTIVO_BAJO     = 1,          // 1: el reset se activa con 0 (botón con pull-up)
	 parameter COUNTER_MAX 				= 23'd6250000
)(
    input  wire       clk,
    input  wire       A,
    input  wire       B,
	 input  wire       rst,
    output reg  [6:0] siete_seg,       // {g,f,e,d,c,b,a}
    output reg  [3:0] digito_sel,      // [0] = unidades A, [1] = decenas A, [2] = unidades B, [1] = decenas B
    output reg        sg               // LED de signo (1 = negativo)
);

    // ------------------------------------------
    // Acondicionamiento del reset
    // Polaridad + sincronización (2 flip-flops)
    // ------------------------------------------
    wire rst_log = RESET_ACTIVO_BAJO ? ~rst : rst;

    reg rst_s1 = 1'b1, rst_s2 = 1'b1;   // Arranca en reset al encender
    always @(posedge clk) begin
        rst_s1 <= rst_log;
        rst_s2 <= rst_s1;
    end

    wire reset = rst_s2;
	 
	 // ------------------------------------------
    // Acondicionamiento de A y B
    // Polaridad + sincronización (2 flip-flops)
    // ------------------------------------------
	 
	 wire A_log = RESET_ACTIVO_BAJO ? ~A : A;
	 reg [22:0] count1 = 0;
	 reg [22:0] count2 = 0;

    reg A_s1 = 1'b0, A_s2 = 1'b0;   // Arranca en 0 al encender
	 reg playerA = 0;
	 
    always @(posedge clk) begin
        A_s1 <= A_log;
        A_s2 <= A_s1;
    end
	 
	 always @(posedge clk) begin
        if (A_s2 != playerA) begin
            if (count1 < COUNTER_MAX) begin
                count1 <= count1 + 1'b1;
            end else begin
                count1 <= 0;
                playerA <= A_s2; // Confirma el nuevo estado estable
            end
        end else begin
            count1 <= 0;
        end
    end
	 
	 wire B_log = RESET_ACTIVO_BAJO ? ~B : B;

    reg B_s1 = 1'b0, B_s2 = 1'b0;   // Arranca en 0 al encender
	 reg playerB = 0; 
	 
    always @(posedge clk) begin
        B_s1 <= B_log;
        B_s2 <= B_s1;
    end
	 
	 always @(posedge clk) begin
        if (B_s2 != playerB) begin
            if (count2 < COUNTER_MAX) begin
                count2 <= count2 + 1'b1;
            end else begin
                count2 <= 0;
                playerB <= B_s2; // Confirma el nuevo estado estable
            end
        end else begin
            count2 <= 0;
        end
    end
	 
	 reg [5:0] contador1 = 5'b0;
	 reg [5:0] contador2 = 5'b0;
	 
	 always @(posedge clk) begin
		  if (contador1 == 5'd20) begin
				contador1 <= 5'b0;
		  end else begin
				if (playerA) begin
					contador1 <= contador1 + 1'b1;
				end
		  end	
	 end
	 
	 always @(posedge clk) begin
		  if (contador2 == 5'd20) begin
				contador2 <= 5'b0;
		  end else begin
				if (playerB) begin
					contador2 <= contador2 + 1'b1;
				end
		  end	
	 end
    

    // ------------------------------------------
    // Conversión binario -> BCD (decenas 0..2, unidades 0..9)
    // ------------------------------------------
    wire [1:0] decenasA;
    wire [3:0] unidadesA;
	 
	 wire [1:0] decenasB;
    wire [3:0] unidadesB;


    bin5_a_bcd u_bcdA (
        .bin(contador1), .decenas(decenasA), .unidades(unidadesA)
    );
	 
	 bin5_a_bcd u_bcdB (
        .bin(contador2), .decenas(decenasB), .unidades(unidadesB)
    );

    // ------------------------------------------
    // Decodificadores 7 segmentos (lógica activa en alto)
    // ------------------------------------------
    // Símbolos del decodificador: 0-9 dígitos, F = apagado

    wire [6:0] seg_unidadesA, seg_decenasA, seg_unidadesB, seg_decenasB;

    decodificador_7seg u_dec_uniA (.simbolo(unidadesA), .seg(seg_unidadesA));
    decodificador_7seg u_dec_decA (.simbolo(decenasA),  .seg(seg_decenasA));
    decodificador_7seg u_dec_uniB (.simbolo(unidadesB), .seg(seg_unidadesB));
    decodificador_7seg u_dec_decB (.simbolo(decenasB),  .seg(seg_decenasB));

    // ------------------------------------------
    // Base de tiempo para el multiplexado
    // ------------------------------------------
    localparam integer DIV   = CLK_HZ / CAMBIO_HZ;          // ~12 500 ciclos a 50 MHz
    localparam integer ANCHO = (DIV > 1) ? $clog2(DIV) : 1;

    reg [ANCHO-1:0] contador = 0;
    reg [1:0]       sel      = 2'd0;   // 0 = unidadesA, 1 = decenasA, 2 = unidadesB, 3 = decenasB

    always @(posedge clk) begin
        if (contador == DIV - 1) begin
            contador <= 0;
            sel      <= (sel == 2'd3) ? 2'd0 : sel + 1'b1;
        end else begin
            contador <= contador + 1'b1;
        end
    end

    // ------------------------------------------
    // Multiplexor con salidas registradas (sin glitches)
    // La polaridad física se aplica solo aquí, una sola vez.
    // ------------------------------------------
    reg [6:0] seg_act;
    reg [3:0] dig_act;
	 
	 // define un bloque de logica combinacional que se actualiza
	 // con cualquier cambio de variable. (*)

    always @(*) begin 
        case (sel)
            2'd0:    begin seg_act = seg_unidadesA; dig_act = 4'b0001; end
            2'd1:    begin seg_act = seg_decenasA;  dig_act = 4'b0010; end
				2'd2:    begin seg_act = seg_unidadesB; dig_act = 4'b0100; end
            default: begin seg_act = seg_decenasB;  dig_act = 4'b1000; end
        endcase
    end

    always @(posedge clk) begin
        siete_seg  <= SEG_ACTIVOS_BAJO ? ~seg_act : seg_act;
        digito_sel <= DIG_ACTIVOS_BAJO ? ~dig_act : dig_act;
    end

endmodule


// ==========================================
// 2. CONVERSOR BINARIO (0..30) -> BCD
// ==========================================
module bin5_a_bcd (
    input  wire [4:0] bin,
    output reg  [1:0] decenas,
    output reg  [3:0] unidades
);
    always @(*) begin
        if (bin >= 5'd20)      begin decenas = 2'd2; unidades = bin - 5'd20; end
        else if (bin >= 5'd10) begin decenas = 2'd1; unidades = bin - 5'd10; end
        else                   begin decenas = 2'd0; unidades = bin[3:0];    end
    end
endmodule


// ==========================================
// 3. DECODIFICADOR 7 SEGMENTOS (activo en alto)
// ==========================================
// Salida {g,f,e,d,c,b,a}. Símbolos extra: F = apagado.
module decodificador_7seg (
    input  wire [3:0] simbolo,
    output reg  [6:0] seg
);
    always @(*) begin
        case (simbolo)               //  gfedcba
            4'd0:    seg = 7'b0111111;
            4'd1:    seg = 7'b0000110;
            4'd2:    seg = 7'b1011011;
            4'd3:    seg = 7'b1001111;
            4'd4:    seg = 7'b1100110;
            4'd5:    seg = 7'b1101101;
            4'd6:    seg = 7'b1111101;
            4'd7:    seg = 7'b0000111;
            4'd8:    seg = 7'b1111111;
            4'd9:    seg = 7'b1101111;
            default: seg = 7'b0000000;   // apagado
        endcase
    end
endmodule