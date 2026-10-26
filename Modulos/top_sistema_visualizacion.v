/*
 * Sistema Sumador con Signo: A+B, -A+B, A-B, -A-B
 * Resultado en signo-magnitud (-30 .. +30) sobre 3 displays de 7 segmentos multiplexados:
 *
 *      [ signo ][ decenas ][ unidades ]
 *      digito_sel[2]  [1]       [0]
 *
 *   Ejemplos:  -25 -> "-25"   +12 -> " 12"   -7 -> "-07"  (o " -7" con APAGAR_CERO_IZQ = 1)
 *
 * FPGA: Cyclone IV EP4CE10E22C8 (reloj de 50 MHz)
 *
 *   nA = 1  -> el operando A se toma negativo (-A)
 *   nB = 1  -> el operando B se toma negativo (-B)
 *   SG = 1  -> el resultado es negativo (el cero nunca se marca negativo)
 *
 * IMPORTANTE: digito_sel ahora tiene 3 bits. En el Pin Planner de Quartus
 * asigna digito_sel[2] al pin de selección del display del signo.
 */

// ==========================================
// 1. MÓDULO TOP
// ==========================================
module top_sistema_visualizacion #(
    parameter CLK_HZ                = 50_000_000, // Reloj de la placa
    parameter CAMBIO_HZ             = 3_000,      // Cambios de display por segundo (1 kHz por display)
    parameter ENTRADAS_ACTIVAS_BAJO = 1,          // 1: switch/botón en "bajo" = 0 lógico (entradas con pull-up)
    parameter SEG_ACTIVOS_BAJO      = 1,          // 1: ánodo común (segmento enciende con 0)
    parameter DIG_ACTIVOS_BAJO      = 1,          // 1: selección de display activa en 0
    parameter APAGAR_CERO_IZQ       = 0           // 1: muestra " -7" / "  7" en lugar de "-07" / " 07"
)(
    input  wire       clk,
    input  wire       A0, input wire A1, input wire A2, input wire A3,
    input  wire       B0, input wire B1, input wire B2, input wire B3,
    input  wire       nA,              // Control de signo de A
    input  wire       nB,              // Control de signo de B
    output reg  [6:0] siete_seg,       // {g,f,e,d,c,b,a}
    output reg  [2:0] digito_sel,      // [0] = unidades, [1] = decenas, [2] = signo
    output reg        SG               // LED de signo (1 = negativo)
);

    // ------------------------------------------
    // Acondicionamiento de entradas
    // Corrige la polaridad y sincroniza al reloj (2 flip-flops)
    // para evitar metaestabilidad con switches/botones externos.
    // ------------------------------------------
    wire [9:0] entrada_pin = {nB, nA, B3, B2, B1, B0, A3, A2, A1, A0};
    wire [9:0] entrada_log = ENTRADAS_ACTIVAS_BAJO ? ~entrada_pin : entrada_pin;

    reg  [9:0] sinc_1 = 10'd0, sinc_2 = 10'd0;
    always @(posedge clk) begin
        sinc_1 <= entrada_log;
        sinc_2 <= sinc_1;
    end

    wire [3:0] A    = sinc_2[3:0];
    wire [3:0] B    = sinc_2[7:4];
    wire       negA = sinc_2[8];
    wire       negB = sinc_2[9];

    // ------------------------------------------
    // Aritmética: suma con signo -> signo + magnitud
    // ------------------------------------------
    wire       signo;
    wire [4:0] magnitud;            // 0 .. 30

    sumador_signo_magnitud u_alu (
        .A(A), .B(B), .negA(negA), .negB(negB),
        .signo(signo), .magnitud(magnitud)
    );

    // ------------------------------------------
    // Conversión binario -> BCD (decenas 0..3, unidades 0..9)
    // ------------------------------------------
    wire [1:0] decenas;
    wire [3:0] unidades;

    bin5_a_bcd u_bcd (
        .bin(magnitud), .decenas(decenas), .unidades(unidades)
    );

    // ------------------------------------------
    // Decodificadores 7 segmentos (lógica activa en alto)
    // ------------------------------------------
    // Símbolos del decodificador: 0-9 dígitos, A = '-', F = apagado
    localparam [3:0] MENOS = 4'hA, APAGADO = 4'hF;

    wire cero_izq = APAGAR_CERO_IZQ && (decenas == 2'd0);

    // Con cero a la izquierda apagado, el '-' se corre junto al número (" -7")
    wire [3:0] sim_decenas = !cero_izq ? {2'b00, decenas} :
                             signo     ? MENOS            : APAGADO;
    wire [3:0] sim_signo   = (signo && !cero_izq) ? MENOS : APAGADO;

    wire [6:0] seg_unidades, seg_decenas, seg_signo;

    decodificador_7seg u_dec_uni (.simbolo(unidades),    .seg(seg_unidades));
    decodificador_7seg u_dec_dec (.simbolo(sim_decenas), .seg(seg_decenas));
    decodificador_7seg u_dec_sig (.simbolo(sim_signo),   .seg(seg_signo));

    // ------------------------------------------
    // Base de tiempo para el multiplexado
    // ------------------------------------------
    localparam integer DIV   = CLK_HZ / CAMBIO_HZ;          // ~16 667 ciclos a 50 MHz
    localparam integer ANCHO = (DIV > 1) ? $clog2(DIV) : 1;

    reg [ANCHO-1:0] contador = 0;
    reg [1:0]       sel      = 2'd0;   // 0 = unidades, 1 = decenas, 2 = signo

    always @(posedge clk) begin
        if (contador == DIV - 1) begin
            contador <= 0;
            sel      <= (sel == 2'd2) ? 2'd0 : sel + 1'b1;
        end else begin
            contador <= contador + 1'b1;
        end
    end

    // ------------------------------------------
    // Multiplexor con salidas registradas (sin glitches)
    // La polaridad física se aplica solo aquí, una sola vez.
    // ------------------------------------------
    reg [6:0] seg_act;
    reg [2:0] dig_act;

    always @(*) begin
        case (sel)
            2'd0:    begin seg_act = seg_unidades; dig_act = 3'b001; end
            2'd1:    begin seg_act = seg_decenas;  dig_act = 3'b010; end
            default: begin seg_act = seg_signo;    dig_act = 3'b100; end
        endcase
    end

    always @(posedge clk) begin
        siete_seg  <= SEG_ACTIVOS_BAJO ? ~seg_act : seg_act;
        digito_sel <= DIG_ACTIVOS_BAJO ? ~dig_act : dig_act;
        SG         <= signo;
    end

endmodule


// ==========================================
// 2. SUMADOR CON SIGNO -> SIGNO-MAGNITUD
// ==========================================
// Cada operando se extiende a 6 bits en complemento a 2 (rango -32..31),
// se suma y se toma el valor absoluto. No depende del acarreo de salida,
// por eso funciona bien también cuando el operando negado vale 0.
module sumador_signo_magnitud (
    input  wire [3:0] A,
    input  wire [3:0] B,
    input  wire       negA,
    input  wire       negB,
    output wire       signo,      // 1 = resultado negativo
    output wire [4:0] magnitud    // |resultado|, 0..30
);
    wire signed [5:0] opA  = negA ? -$signed({2'b00, A}) : $signed({2'b00, A});
    wire signed [5:0] opB  = negB ? -$signed({2'b00, B}) : $signed({2'b00, B});
    wire signed [5:0] suma = opA + opB;                  // -30 .. +30, nunca desborda

    assign signo = suma[5];
    wire [5:0] absoluto = signo ? -suma : suma;
    assign magnitud = absoluto[4:0];
endmodule


// ==========================================
// 3. CONVERSOR BINARIO (0..30) -> BCD
// ==========================================
module bin5_a_bcd (
    input  wire [4:0] bin,
    output reg  [1:0] decenas,
    output reg  [3:0] unidades
);
    always @(*) begin
        if (bin >= 5'd30)      begin decenas = 2'd3; unidades = bin - 5'd30; end
        else if (bin >= 5'd20) begin decenas = 2'd2; unidades = bin - 5'd20; end
        else if (bin >= 5'd10) begin decenas = 2'd1; unidades = bin - 5'd10; end
        else                   begin decenas = 2'd0; unidades = bin[3:0];    end
    end
endmodule


// ==========================================
// 4. DECODIFICADOR 7 SEGMENTOS (activo en alto)
// ==========================================
// Salida {g,f,e,d,c,b,a}. Símbolos extra: A = '-', F = apagado.
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
            4'hA:    seg = 7'b1000000;   // signo menos
            default: seg = 7'b0000000;   // apagado
        endcase
    end
endmodule
