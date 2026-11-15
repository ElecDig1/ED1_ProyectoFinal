
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity prueba_pong_matriz is
    port (
        clk : in std_logic;

        -- Pulsadores activos en bajo
        j1_arriba : in std_logic;
        j1_abajo  : in std_logic;
        j2_arriba : in std_logic;
        j2_abajo  : in std_logic;

        -- Matriz LED 8x8
        filas    : out std_logic_vector(7 downto 0);
        columnas : out std_logic_vector(7 downto 0)
    );
end entity prueba_pong_matriz;

architecture Behavioral of prueba_pong_matriz is

    --------------------------------------------------
    -- 1. CONSTANTES
    --------------------------------------------------

    -- Frecuencia del reloj: 50 MHz
    constant CLK_FREQ : integer := 50000000;

    -- Multiplexacion de matriz: 125 Hz
    constant SCAN_DIV : integer := 6250;
    constant SET_COL  : integer := 100;
    constant BLANKING : integer := 200;

    -- Velocidad de pelota: 350 ms
    constant GAME_DIV : integer := 17500000;

    -- Pausa de 1 segundo despues de cada punto
    constant PAUSA_DIV : integer := 50000000;

    -- Antirrebote de 10 ms
    constant DEBOUNCE_MAX : integer := 499999;

    --------------------------------------------------
    -- 2. CONTADORES
    --------------------------------------------------

    signal scan_count : integer range 0 to SCAN_DIV-1 := 0;
    signal scan_row   : integer range 0 to 7 := 0;

    signal game_count : integer range 0 to GAME_DIV-1 := 0;

    signal pausa_count : integer range 0 to PAUSA_DIV-1 := 0;
    signal pausa_activa : std_logic := '0';

    --------------------------------------------------
    -- 3. PALETAS
    --------------------------------------------------

    -- Posicion superior de cada paleta
    -- Altura: 3 LED
    signal paleta_izq : integer range 0 to 5 := 2;
    signal paleta_der : integer range 0 to 5 := 2;

    --------------------------------------------------
    -- 4. PELOTA
    --------------------------------------------------

    -- Posicion inicial aproximada al centro
    signal pelota_x : integer range 1 to 6 := 3;
    signal pelota_y : integer range 0 to 7 := 3;

    -- Direcciones:
    -- -1: izquierda / arriba
    --  0: sin movimiento vertical
    --  1: derecha / abajo
    signal dir_x : integer range -1 to 1 := 1;
    signal dir_y : integer range -1 to 1 := 1;

    --------------------------------------------------
    -- 5. PUNTUACION INTERNA
    --------------------------------------------------

    signal puntos_j1 : integer range 0 to 99 := 0;
    signal puntos_j2 : integer range 0 to 99 := 0;

    --------------------------------------------------
    -- 6. PULSADORES
    --------------------------------------------------

    signal botones : std_logic_vector(3 downto 0);

    signal sync1 : std_logic_vector(3 downto 0)
        := (others => '1');

    signal sync2 : std_logic_vector(3 downto 0)
        := (others => '1');

    signal estables : std_logic_vector(3 downto 0)
        := (others => '1');

    signal pulsos : std_logic_vector(3 downto 0)
        := (others => '0');

    type contador_tipo is array (0 to 3)
        of integer range 0 to DEBOUNCE_MAX;

    signal debounce_count : contador_tipo :=
        (others => 0);

    --------------------------------------------------
    -- 7. MATRIZ LED
    --------------------------------------------------

    type matriz_tipo is array (0 to 7)
        of std_logic_vector(7 downto 0);

    signal imagen : matriz_tipo :=
        (others => (others => '0'));

    signal filas_reg : std_logic_vector(7 downto 0)
        := (others => '0');

    signal columnas_reg : std_logic_vector(7 downto 0)
        := (others => '1');

begin

    --------------------------------------------------
    -- 8. ENTRADAS DE LOS PULSADORES
    --------------------------------------------------

    botones(0) <= j1_arriba;
    botones(1) <= j1_abajo;
    botones(2) <= j2_arriba;
    botones(3) <= j2_abajo;

    --------------------------------------------------
    -- 9. SINCRONIZACION Y ANTIRREBOTE
    --------------------------------------------------

    process(clk)
    begin
        if rising_edge(clk) then

            sync1 <= botones;
            sync2 <= sync1;

            pulsos <= (others => '0');

            for i in 0 to 3 loop

                if sync2(i) = estables(i) then

                    debounce_count(i) <= 0;

                elsif debounce_count(i) = DEBOUNCE_MAX then

                    debounce_count(i) <= 0;
                    estables(i) <= sync2(i);

                    if sync2(i) = '0' then
                        pulsos(i) <= '1';
                    end if;

                else
                    debounce_count(i) <=
                        debounce_count(i) + 1;
                end if;

            end loop;

        end if;
    end process;

    --------------------------------------------------
    -- 10. MOVIMIENTO DE LAS PALETAS
    --------------------------------------------------

    process(clk)
    begin
        if rising_edge(clk) then

            -- JUGADOR 1: PALETA IZQUIERDA

            if pulsos(0) = '1' and
               pulsos(1) = '0' then

                if paleta_izq > 0 then
                    paleta_izq <= paleta_izq - 1;
                end if;

            elsif pulsos(1) = '1' and
                  pulsos(0) = '0' then

                if paleta_izq < 5 then
                    paleta_izq <= paleta_izq + 1;
                end if;

            end if;

            -- JUGADOR 2: PALETA DERECHA

            if pulsos(2) = '1' and
               pulsos(3) = '0' then

                if paleta_der > 0 then
                    paleta_der <= paleta_der - 1;
                end if;

            elsif pulsos(3) = '1' and
                  pulsos(2) = '0' then

                if paleta_der < 5 then
                    paleta_der <= paleta_der + 1;
                end if;

            end if;

        end if;
    end process;

    --------------------------------------------------
    -- 11. MOVIMIENTO DE LA PELOTA
    --------------------------------------------------

    process(clk)

        variable nx : integer;
        variable ny : integer;
        variable dx : integer;
        variable dy : integer;

    begin
        if rising_edge(clk) then

            -- PAUSA DESPUES DE ANOTAR

            if pausa_activa = '1' then

                game_count <= 0;

                if pausa_count = PAUSA_DIV-1 then

                    pausa_count <= 0;
                    pausa_activa <= '0';

                    -- Preparar movimiento inmediato
                    -- al finalizar la pausa
                    game_count <= GAME_DIV-1;

                else
                    pausa_count <= pausa_count + 1;
                end if;

            -- MOVIMIENTO NORMAL

            elsif game_count = GAME_DIV-1 then

                game_count <= 0;

                -- Calcular siguiente posicion
                nx := pelota_x + dir_x;
                ny := pelota_y + dir_y;

                dx := dir_x;
                dy := dir_y;

                --------------------------------------
                -- REBOTE SUPERIOR E INFERIOR
                --------------------------------------

                if ny < 0 then

                    ny := 1;
                    dy := 1;

                elsif ny > 7 then

                    ny := 6;
                    dy := -1;

                end if;

                --------------------------------------
                -- PALETA IZQUIERDA
                --------------------------------------

                if nx <= 0 then

                    if ny >= paleta_izq and
                       ny <= paleta_izq + 2 then

                        -- Rebote hacia la derecha
                        nx := 1;
                        dx := 1;

                        -- Extremo superior: 45 grados
                        if ny = paleta_izq then
                            dy := -1;

                        -- Extremo inferior: 45 grados
                        elsif ny = paleta_izq + 2 then
                            dy := 1;

                        -- Centro: horizontal
                        else
                            dy := 0;

                        end if;

                    else

                        -- PUNTO PARA JUGADOR 2
                        if puntos_j2 < 99 then
                            puntos_j2 <= puntos_j2 + 1;
                        end if;

                        -- Regresar al centro
                        nx := 3;
                        ny := 3;

                        -- Nuevo saque hacia la izquierda
                        dx := -1;
                        dy := 1;

                        -- Activar pausa de 1 segundo
                        pausa_activa <= '1';
                        pausa_count <= 0;

                    end if;

                --------------------------------------
                -- PALETA DERECHA
                --------------------------------------

                elsif nx >= 7 then

                    if ny >= paleta_der and
                       ny <= paleta_der + 2 then

                        -- Rebote hacia la izquierda
                        nx := 6;
                        dx := -1;

                        -- Extremo superior: 45 grados
                        if ny = paleta_der then
                            dy := -1;

                        -- Extremo inferior: 45 grados
                        elsif ny = paleta_der + 2 then
                            dy := 1;

                        -- Centro: horizontal
                        else
                            dy := 0;

                        end if;

                    else

                        -- PUNTO PARA JUGADOR 1
                        if puntos_j1 < 99 then
                            puntos_j1 <= puntos_j1 + 1;
                        end if;

                        -- Regresar al centro
                        nx := 3;
                        ny := 3;

                        -- Nuevo saque hacia la derecha
                        dx := 1;
                        dy := -1;

                        -- Activar pausa de 1 segundo
                        pausa_activa <= '1';
                        pausa_count <= 0;

                    end if;

                end if;

                --------------------------------------
                -- ACTUALIZAR PELOTA
                --------------------------------------

                pelota_x <= nx;
                pelota_y <= ny;

                dir_x <= dx;
                dir_y <= dy;

            else

                game_count <= game_count + 1;

            end if;

        end if;
    end process;

    --------------------------------------------------
    -- 12. GENERACION DE LA IMAGEN
    --------------------------------------------------

    process(paleta_izq, paleta_der,
            pelota_x, pelota_y)

        variable pantalla : matriz_tipo;

    begin

        pantalla := (others => (others => '0'));

        -- Paleta izquierda: columna 1
        for i in 0 to 2 loop
            pantalla(paleta_izq+i)(7) := '1';
        end loop;

        -- Paleta derecha: columna 8
        for i in 0 to 2 loop
            pantalla(paleta_der+i)(0) := '1';
        end loop;

        -- Pelota: un solo LED
        pantalla(pelota_y)(7-pelota_x) := '1';

        imagen <= pantalla;

    end process;

    --------------------------------------------------
    -- 13. MULTIPLEXACION DE LA MATRIZ
    --------------------------------------------------

    process(clk)

        variable fila_sel : std_logic_vector(7 downto 0);

    begin
        if rising_edge(clk) then

            if scan_count = SCAN_DIV-1 then

                scan_count <= 0;

                -- Apagar antes de cambiar fila
                filas_reg <= (others => '0');
                columnas_reg <= (others => '1');

                if scan_row = 7 then
                    scan_row <= 0;
                else
                    scan_row <= scan_row + 1;
                end if;

            else

                scan_count <= scan_count + 1;

                -- Preparar columnas
                if scan_count = SET_COL then

                    columnas_reg <=
                        not imagen(scan_row);

                end if;

                -- Activar una sola fila
                if scan_count = BLANKING then

                    fila_sel := (others => '0');
                    fila_sel(scan_row) := '1';

                    filas_reg <= fila_sel;

                end if;

            end if;

        end if;
    end process;

    --------------------------------------------------
    -- 14. SALIDAS
    --------------------------------------------------

    filas <= filas_reg;
    columnas <= columnas_reg;

end architecture Behavioral;