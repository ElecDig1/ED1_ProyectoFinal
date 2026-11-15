/*
 * PONG en matriz LED 8x8 + marcador en 4 displays de 7 segmentos
 *
 * FPGA: Cyclone IV EP4CE10E22C8 (reloj de 50 MHz)
 *
 * Origen:
 *   - prueba8x8.vhd   -> traducido a Verilog (modulos pong_juego y matriz_8x8)
 *   - top_marcador.v  -> adaptado (modulo marcador_7seg)
 *
 * Mejoras de la integracion:
 *   - El marcador ya no usa botones A/B: suma automaticamente cuando el
 *     juego detecta un punto (pulso de 1 ciclo punto_j1 / punto_j2).
 *   - Contadores en BCD (00..99) por jugador: no hace falta conversor.
 *   - Partida a PUNTOS_GANAR: al llegar, el juego se congela, la pelota se
 *     apaga y el puntaje del ganador parpadea en los displays.
 *   - Boton de reset unico: reinicia paletas, pelota y marcador.
 *   - Pausa de 1 s tambien al arrancar/reiniciar, para que los jugadores
 *     se preparen.
 *   - Sonido 8 bits en buzzer pasivo (pin 141): pitido agudo al golpear
 *     una paleta, pitido grave al rebotar en la pared y melodia de victoria.
 *
 * Mapa de displays (igual que top_marcador):
 *   digito_sel[0] = unidades J1   digito_sel[1] = decenas J1
 *   digito_sel[2] = unidades J2   digito_sel[3] = decenas J2
 */

// ==========================================================
// 1. MODULO TOP
// ==========================================================
module pong_top #(
    parameter CLK_HZ            = 50_000_000,
    parameter GAME_DIV          = 17_500_000, // 350 ms por paso de pelota
    parameter PAUSA_DIV         = 50_000_000, // 1 s de pausa tras cada punto
    parameter DEBOUNCE_MAX      = 499_999,    // 10 ms de antirrebote
    parameter SCAN_DIV          = 6_250,      // 125 Hz por cuadro de la matriz
    parameter CAMBIO_HZ         = 4_000,      // 1 kHz por display
    parameter PARPADEO_DIV      = 12_500_000, // 250 ms (parpadeo del ganador)
    parameter PUNTOS_GANAR      = 10,         // 1..99
    parameter SEG_ACTIVOS_BAJO  = 1,          // 1: anodo comun
    parameter DIG_ACTIVOS_BAJO  = 1,          // 1: seleccion de display en 0
    parameter RESET_ACTIVO_BAJO = 1,          // 1: boton de reset con pull-up
    parameter BUZZER_ACTIVO_BAJO = 1          // 1: buzzer suena con 0 (reposo en 1)
)(
    input  wire       clk,
    input  wire       rst,

    // Pulsadores activos en bajo
    input  wire       j1_arriba,
    input  wire       j1_abajo,
    input  wire       j2_arriba,
    input  wire       j2_abajo,

    // Matriz LED 8x8 (filas activas en alto, columnas activas en bajo)
    output wire [7:0] filas,
    output wire [7:0] columnas,

    // Marcador 7 segmentos
    output wire [6:0] siete_seg,   // {g,f,e,d,c,b,a}
    output wire [3:0] digito_sel,

    // Buzzer pasivo
    output wire       buzzer
);

    // ------------------------------------------
    // Reset: polaridad + sincronizacion (2 FF)
    // ------------------------------------------
    wire rst_log = RESET_ACTIVO_BAJO ? ~rst : rst;

    reg rst_s1 = 1'b1, rst_s2 = 1'b1;   // Arranca en reset al encender
    always @(posedge clk) begin
        rst_s1 <= rst_log;
        rst_s2 <= rst_s1;
    end
    wire reset = rst_s2;

    // ------------------------------------------
    // Antirrebote de los 4 pulsadores
    // ------------------------------------------
    wire p_j1_arr, p_j1_aba, p_j2_arr, p_j2_aba;

    antirrebote #(.MAX(DEBOUNCE_MAX)) u_db0 (.clk(clk), .btn_n(j1_arriba), .pulso(p_j1_arr));
    antirrebote #(.MAX(DEBOUNCE_MAX)) u_db1 (.clk(clk), .btn_n(j1_abajo),  .pulso(p_j1_aba));
    antirrebote #(.MAX(DEBOUNCE_MAX)) u_db2 (.clk(clk), .btn_n(j2_arriba), .pulso(p_j2_arr));
    antirrebote #(.MAX(DEBOUNCE_MAX)) u_db3 (.clk(clk), .btn_n(j2_abajo),  .pulso(p_j2_aba));

    // ------------------------------------------
    // Paletas (posicion superior, altura 3 LED)
    // ------------------------------------------
    wire fin_juego;
    reg [2:0] paleta_izq = 3'd2;
    reg [2:0] paleta_der = 3'd2;

    always @(posedge clk) begin
        if (reset) begin
            paleta_izq <= 3'd2;
            paleta_der <= 3'd2;
        end else if (!fin_juego) begin
            // Jugador 1: paleta izquierda
            if (p_j1_arr && !p_j1_aba) begin
                if (paleta_izq > 0) paleta_izq <= paleta_izq - 1'b1;
            end else if (p_j1_aba && !p_j1_arr) begin
                if (paleta_izq < 5) paleta_izq <= paleta_izq + 1'b1;
            end

            // Jugador 2: paleta derecha
            if (p_j2_arr && !p_j2_aba) begin
                if (paleta_der > 0) paleta_der <= paleta_der - 1'b1;
            end else if (p_j2_aba && !p_j2_arr) begin
                if (paleta_der < 5) paleta_der <= paleta_der + 1'b1;
            end
        end
    end

    // ------------------------------------------
    // Logica de la pelota
    // ------------------------------------------
    wire [2:0] pelota_x, pelota_y;
    wire       punto_j1, punto_j2;
    wire       rebote_paleta, rebote_pared;

    pong_juego #(
        .GAME_DIV (GAME_DIV),
        .PAUSA_DIV(PAUSA_DIV)
    ) u_juego (
        .clk       (clk),
        .reset     (reset),
        .fin_juego (fin_juego),
        .paleta_izq(paleta_izq),
        .paleta_der(paleta_der),
        .pelota_x  (pelota_x),
        .pelota_y  (pelota_y),
        .punto_j1     (punto_j1),
        .punto_j2     (punto_j2),
        .rebote_paleta(rebote_paleta),
        .rebote_pared (rebote_pared)
    );

    // ------------------------------------------
    // Matriz LED 8x8
    // ------------------------------------------
    matriz_8x8 #(.SCAN_DIV(SCAN_DIV)) u_matriz (
        .clk           (clk),
        .paleta_izq    (paleta_izq),
        .paleta_der    (paleta_der),
        .pelota_x      (pelota_x),
        .pelota_y      (pelota_y),
        .mostrar_pelota(~fin_juego),
        .filas         (filas),
        .columnas      (columnas)
    );

    // ------------------------------------------
    // Marcador en 7 segmentos
    // ------------------------------------------
    marcador_7seg #(
        .CLK_HZ          (CLK_HZ),
        .CAMBIO_HZ       (CAMBIO_HZ),
        .PARPADEO_DIV    (PARPADEO_DIV),
        .PUNTOS_GANAR    (PUNTOS_GANAR),
        .SEG_ACTIVOS_BAJO(SEG_ACTIVOS_BAJO),
        .DIG_ACTIVOS_BAJO(DIG_ACTIVOS_BAJO)
    ) u_marcador (
        .clk       (clk),
        .reset     (reset),
        .punto_j1  (punto_j1),
        .punto_j2  (punto_j2),
        .fin_juego (fin_juego),
        .siete_seg (siete_seg),
        .digito_sel(digito_sel)
    );

    // ------------------------------------------
    // Sonido 8 bits
    // ------------------------------------------
    sonido_8bit #(
        .CLK_HZ     (CLK_HZ),
        .ACTIVO_BAJO(BUZZER_ACTIVO_BAJO)
    ) u_sonido (
        .clk          (clk),
        .reset        (reset),
        .rebote_paleta(rebote_paleta),
        .rebote_pared (rebote_pared),
        .fin_juego    (fin_juego),
        .buzzer       (buzzer)
    );

endmodule


// ==========================================================
// 2. ANTIRREBOTE (pulsador activo en bajo -> pulso de 1 ciclo al presionar)
// ==========================================================
module antirrebote #(
    parameter MAX = 499_999
)(
    input  wire clk,
    input  wire btn_n,
    output reg  pulso = 1'b0
);
    reg s1 = 1'b1, s2 = 1'b1, estable = 1'b1;
    reg [$clog2(MAX+1)-1:0] cnt = 0;

    always @(posedge clk) begin
        s1    <= btn_n;
        s2    <= s1;
        pulso <= 1'b0;

        if (s2 == estable) begin
            cnt <= 0;
        end else if (cnt == MAX) begin
            cnt     <= 0;
            estable <= s2;
            if (s2 == 1'b0) pulso <= 1'b1;   // flanco de presion confirmado
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
endmodule


// ==========================================================
// 3. LOGICA DEL JUEGO (pelota, rebotes y deteccion de puntos)
// ==========================================================
module pong_juego #(
    parameter GAME_DIV  = 17_500_000,
    parameter PAUSA_DIV = 50_000_000
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       fin_juego,
    input  wire [2:0] paleta_izq,
    input  wire [2:0] paleta_der,
    output reg  [2:0] pelota_x = 3'd3,   // 1..6
    output reg  [2:0] pelota_y = 3'd3,   // 0..7
    output reg        punto_j1 = 1'b0,   // pulso de 1 ciclo
    output reg        punto_j2 = 1'b0,   // pulso de 1 ciclo
    output reg        rebote_paleta = 1'b0, // pulso: golpe en una paleta
    output reg        rebote_pared  = 1'b0  // pulso: rebote arriba/abajo
);
    // Direcciones con signo: -1 izquierda/arriba, 0 quieto, +1 derecha/abajo
    reg signed [1:0] dir_x = 2'sd1;
    reg signed [1:0] dir_y = 2'sd1;

    reg [$clog2(GAME_DIV)-1:0]  game_count  = 0;
    reg [$clog2(PAUSA_DIV)-1:0] pausa_count = 0;
    reg                         pausa       = 1'b1;  // pausa inicial de 1 s

    // Variables temporales (asignacion bloqueante)
    reg signed [4:0] nx, ny, pi, pd;
    reg signed [1:0] dx, dy;

    always @(posedge clk) begin
        punto_j1      <= 1'b0;
        punto_j2      <= 1'b0;
        rebote_paleta <= 1'b0;
        rebote_pared  <= 1'b0;

        if (reset) begin
            pelota_x    <= 3'd3;
            pelota_y    <= 3'd3;
            dir_x       <= 2'sd1;
            dir_y       <= 2'sd1;
            game_count  <= 0;
            pausa_count <= 0;
            pausa       <= 1'b1;

        end else if (fin_juego) begin
            // Partida terminada: todo congelado hasta reset
            game_count <= 0;

        end else if (pausa) begin
            // Pausa despues de anotar
            game_count <= 0;
            if (pausa_count == PAUSA_DIV-1) begin
                pausa_count <= 0;
                pausa       <= 1'b0;
                game_count  <= GAME_DIV-1;    // mover apenas termina la pausa
            end else begin
                pausa_count <= pausa_count + 1'b1;
            end

        end else if (game_count == GAME_DIV-1) begin
            game_count <= 0;

            nx = $signed({2'b00, pelota_x}) + dir_x;
            ny = $signed({2'b00, pelota_y}) + dir_y;
            dx = dir_x;
            dy = dir_y;
            pi = $signed({2'b00, paleta_izq});
            pd = $signed({2'b00, paleta_der});

            // Rebote superior e inferior
            if (ny < 0) begin
                ny = 5'sd1;  dy = 2'sd1;
                rebote_pared <= 1'b1;
            end else if (ny > 7) begin
                ny = 5'sd6;  dy = -2'sd1;
                rebote_pared <= 1'b1;
            end

            // Paleta izquierda
            if (nx <= 0) begin
                if (ny >= pi && ny <= pi + 2) begin
                    nx = 5'sd1;  dx = 2'sd1;
                    rebote_paleta <= 1'b1;
                    if      (ny == pi)     dy = -2'sd1;  // extremo superior
                    else if (ny == pi + 2) dy =  2'sd1;  // extremo inferior
                    else                   dy =  2'sd0;  // centro: horizontal
                end else begin
                    // PUNTO PARA JUGADOR 2
                    punto_j2 <= 1'b1;
                    nx = 5'sd3;  ny = 5'sd3;
                    dx = -2'sd1; dy = 2'sd1;    // saque hacia quien perdio
                    pausa       <= 1'b1;
                    pausa_count <= 0;
                end

            // Paleta derecha
            end else if (nx >= 7) begin
                if (ny >= pd && ny <= pd + 2) begin
                    nx = 5'sd6;  dx = -2'sd1;
                    rebote_paleta <= 1'b1;
                    if      (ny == pd)     dy = -2'sd1;
                    else if (ny == pd + 2) dy =  2'sd1;
                    else                   dy =  2'sd0;
                end else begin
                    // PUNTO PARA JUGADOR 1
                    punto_j1 <= 1'b1;
                    nx = 5'sd3;  ny = 5'sd3;
                    dx = 2'sd1;  dy = -2'sd1;
                    pausa       <= 1'b1;
                    pausa_count <= 0;
                end
            end

            pelota_x <= nx[2:0];
            pelota_y <= ny[2:0];
            dir_x    <= dx;
            dir_y    <= dy;

        end else begin
            game_count <= game_count + 1'b1;
        end
    end
endmodule


// ==========================================================
// 4. MATRIZ LED 8x8 (imagen + multiplexado por filas)
// ==========================================================
// Columna fisica 7 = paleta izquierda (x = 0)
// Columna fisica 0 = paleta derecha   (x = 7)
module matriz_8x8 #(
    parameter SCAN_DIV = 6_250,
    parameter SET_COL  = 100,
    parameter BLANKING = 200
)(
    input  wire       clk,
    input  wire [2:0] paleta_izq,
    input  wire [2:0] paleta_der,
    input  wire [2:0] pelota_x,
    input  wire [2:0] pelota_y,
    input  wire       mostrar_pelota,
    output reg  [7:0] filas    = 8'h00,
    output reg  [7:0] columnas = 8'hFF
);
    reg [$clog2(SCAN_DIV)-1:0] scan_count = 0;
    reg [2:0]                  scan_row   = 0;

    // Contenido de la fila que se esta barriendo
    reg [7:0] fila_img;
    always @(*) begin
        fila_img = 8'b0;
        if (scan_row >= paleta_izq && scan_row <= paleta_izq + 2) fila_img[7] = 1'b1;
        if (scan_row >= paleta_der && scan_row <= paleta_der + 2) fila_img[0] = 1'b1;
        if (mostrar_pelota && scan_row == pelota_y)               fila_img[7 - pelota_x] = 1'b1;
    end

    always @(posedge clk) begin
        if (scan_count == SCAN_DIV-1) begin
            scan_count <= 0;
            filas      <= 8'h00;          // apagar antes de cambiar de fila
            columnas   <= 8'hFF;
            scan_row   <= scan_row + 1'b1; // 7 -> 0 por desborde
        end else begin
            scan_count <= scan_count + 1'b1;
            if (scan_count == SET_COL)
                columnas <= ~fila_img;     // columnas activas en bajo
            if (scan_count == BLANKING)
                filas <= 8'b1 << scan_row; // una sola fila activa
        end
    end
endmodule


// ==========================================================
// 5. MARCADOR 7 SEGMENTOS (contadores BCD + multiplexado)
// ==========================================================
module marcador_7seg #(
    parameter CLK_HZ           = 50_000_000,
    parameter CAMBIO_HZ        = 4_000,
    parameter PARPADEO_DIV     = 12_500_000,
    parameter PUNTOS_GANAR     = 10,
    parameter SEG_ACTIVOS_BAJO = 1,
    parameter DIG_ACTIVOS_BAJO = 1
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       punto_j1,
    input  wire       punto_j2,
    output wire       fin_juego,
    output reg  [6:0] siete_seg  = 7'h7F,
    output reg  [3:0] digito_sel = 4'hF
);
    localparam [3:0] META_DEC = PUNTOS_GANAR / 10;
    localparam [3:0] META_UNI = PUNTOS_GANAR % 10;

    // Puntajes en BCD
    reg [3:0] dec1 = 0, uni1 = 0;   // jugador 1
    reg [3:0] dec2 = 0, uni2 = 0;   // jugador 2

    wire gana_j1 = (dec1 == META_DEC) && (uni1 == META_UNI);
    wire gana_j2 = (dec2 == META_DEC) && (uni2 == META_UNI);
    assign fin_juego = gana_j1 | gana_j2;

    always @(posedge clk) begin
        if (reset) begin
            dec1 <= 0; uni1 <= 0;
            dec2 <= 0; uni2 <= 0;
        end else if (!fin_juego) begin
            if (punto_j1) begin
                if (uni1 == 4'd9) begin uni1 <= 0; dec1 <= dec1 + 1'b1; end
                else                    uni1 <= uni1 + 1'b1;
            end
            if (punto_j2) begin
                if (uni2 == 4'd9) begin uni2 <= 0; dec2 <= dec2 + 1'b1; end
                else                    uni2 <= uni2 + 1'b1;
            end
        end
    end

    // Parpadeo del ganador
    reg [$clog2(PARPADEO_DIV)-1:0] parp_count = 0;
    reg                            parp       = 1'b1;
    always @(posedge clk) begin
        if (!fin_juego) begin
            parp_count <= 0;
            parp       <= 1'b1;
        end else if (parp_count == PARPADEO_DIV-1) begin
            parp_count <= 0;
            parp       <= ~parp;
        end else begin
            parp_count <= parp_count + 1'b1;
        end
    end

    // Decodificadores (activos en alto)
    wire [6:0] s_uni1, s_dec1, s_uni2, s_dec2;
    decodificador_7seg u_d0 (.simbolo(uni1), .seg(s_uni1));
    decodificador_7seg u_d1 (.simbolo(dec1), .seg(s_dec1));
    decodificador_7seg u_d2 (.simbolo(uni2), .seg(s_uni2));
    decodificador_7seg u_d3 (.simbolo(dec2), .seg(s_dec2));

    // Base de tiempo del multiplexado
    localparam integer DIV   = CLK_HZ / CAMBIO_HZ;
    localparam integer ANCHO = (DIV > 1) ? $clog2(DIV) : 1;

    reg [ANCHO-1:0] contador = 0;
    reg [1:0]       sel      = 2'd0;

    always @(posedge clk) begin
        if (contador == DIV - 1) begin
            contador <= 0;
            sel      <= sel + 1'b1;
        end else begin
            contador <= contador + 1'b1;
        end
    end

    // Multiplexor
    reg [6:0] seg_act;
    reg [3:0] dig_act;
    always @(*) begin
        case (sel)
            2'd0:    begin seg_act = s_uni1; dig_act = 4'b0001; end
            2'd1:    begin seg_act = s_dec1; dig_act = 4'b0010; end
            2'd2:    begin seg_act = s_uni2; dig_act = 4'b0100; end
            default: begin seg_act = s_dec2; dig_act = 4'b1000; end
        endcase
        // Apagar los digitos del ganador en la fase "off" del parpadeo
        if (!parp && ((gana_j1 && !sel[1]) || (gana_j2 && sel[1])))
            seg_act = 7'b0000000;
    end

    // Salidas registradas; polaridad fisica aplicada solo aqui
    always @(posedge clk) begin
        siete_seg  <= SEG_ACTIVOS_BAJO ? ~seg_act : seg_act;
        digito_sel <= DIG_ACTIVOS_BAJO ? ~dig_act : dig_act;
    end
endmodule


// ==========================================================
// 6. SONIDO 8 BITS (buzzer pasivo, onda cuadrada)
// ==========================================================
// Prioridad: melodia de victoria > golpe de paleta > rebote en pared.
// Un sonido nuevo reinicia al que estaba sonando (salvo la melodia).
module sonido_8bit #(
    parameter CLK_HZ      = 50_000_000,
    parameter ACTIVO_BAJO = 1
)(
    input  wire clk,
    input  wire reset,
    input  wire rebote_paleta,
    input  wire rebote_pared,
    input  wire fin_juego,
    output wire buzzer
);
    // Medio periodo (ciclos) para una frecuencia f: CLK_HZ / (2*f)
    localparam integer MS = CLK_HZ / 1000;

    // Efectos de colision
    localparam integer H_PALETA = CLK_HZ / (2*1000);  // 1000 Hz
    localparam integer D_PALETA = 40 * MS;            // 40 ms
    localparam integer H_PARED  = CLK_HZ / (2*500);   // 500 Hz
    localparam integer D_PARED  = 30 * MS;            // 30 ms

    // Melodia de victoria: Do5 - Mi5 - Sol5 - Do6
    localparam integer H_DO5  = CLK_HZ / (2*523);
    localparam integer H_MI5  = CLK_HZ / (2*659);
    localparam integer H_SOL5 = CLK_HZ / (2*784);
    localparam integer H_DO6  = CLK_HZ / (2*1047);
    localparam integer D_NOTA = 130 * MS;             // notas cortas
    localparam integer D_FIN  = 450 * MS;             // nota final larga
    localparam integer GAP    = 20 * MS;              // silencio entre notas

    reg [24:0] medio    = 0;     // medio periodo del tono actual
    reg [24:0] tono_cnt = 0;
    reg [24:0] dur      = 0;     // ciclos que le quedan al sonido
    reg        onda     = 1'b0;
    reg        activo   = 1'b0;
    reg        melodia  = 1'b0;
    reg [1:0]  nota     = 2'd0;
    reg        fin_prev = 1'b0;

    wire gana = fin_juego & ~fin_prev;   // flanco: alguien acaba de ganar

    function [24:0] medio_nota(input [1:0] n);
        case (n)
            2'd0:    medio_nota = H_DO5;
            2'd1:    medio_nota = H_MI5;
            2'd2:    medio_nota = H_SOL5;
            default: medio_nota = H_DO6;
        endcase
    endfunction

    always @(posedge clk) begin
        fin_prev <= fin_juego;

        if (reset) begin
            activo   <= 1'b0;
            melodia  <= 1'b0;
            onda     <= 1'b0;
            tono_cnt <= 0;
            dur      <= 0;

        end else if (gana) begin
            melodia  <= 1'b1;
            activo   <= 1'b1;
            nota     <= 2'd0;
            medio    <= H_DO5;
            dur      <= D_NOTA;
            tono_cnt <= 0;

        end else if (!melodia && rebote_paleta) begin
            activo   <= 1'b1;
            medio    <= H_PALETA;
            dur      <= D_PALETA;
            tono_cnt <= 0;

        end else if (!melodia && rebote_pared) begin
            activo   <= 1'b1;
            medio    <= H_PARED;
            dur      <= D_PARED;
            tono_cnt <= 0;

        end else if (activo) begin
            // Oscilador de onda cuadrada
            if (tono_cnt >= medio - 1) begin
                tono_cnt <= 0;
                onda     <= ~onda;
            end else begin
                tono_cnt <= tono_cnt + 1'b1;
            end

            // Duracion y paso a la siguiente nota
            if (dur == 0) begin
                if (melodia && nota != 2'd3) begin
                    nota  <= nota + 1'b1;
                    medio <= medio_nota(nota + 1'b1);
                    dur   <= (nota == 2'd2) ? D_FIN : D_NOTA;
                end else begin
                    activo  <= 1'b0;
                    melodia <= 1'b0;
                    onda    <= 1'b0;
                end
            end else begin
                dur <= dur - 1'b1;
            end
        end
    end

    // Silencio corto al final de cada nota de la melodia (articulacion)
    wire silencio = melodia && (dur < GAP);
    wire sonando  = activo & onda & ~silencio;

    assign buzzer = ACTIVO_BAJO ? ~sonando : sonando;
endmodule


// ==========================================================
// 7. DECODIFICADOR 7 SEGMENTOS (activo en alto) {g,f,e,d,c,b,a}
// ==========================================================
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
