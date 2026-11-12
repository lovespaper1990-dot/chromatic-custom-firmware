library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity standby_cpu_case is
    generic (double_speed : boolean);
    port (passed : out boolean := false);
end entity;

architecture sim of standby_cpu_case is
    signal clk, request, bus_busy, ce, ce2, enable, frozen : std_logic := '0';
    signal reset : std_logic := '1';
    signal rd_n, wr_n : std_logic;
    signal address : std_logic_vector(15 downto 0);
    signal din, dout, count, marker : std_logic_vector(7 downto 0) := x"00";
    signal state_address : std_logic_vector(9 downto 0) := (others => '0');
    signal state_word : std_logic_vector(63 downto 0);
    type program_t is array (natural range <>) of std_logic_vector(7 downto 0);
    -- LD HL,$C000; INC (HL); LD A,(HL); XOR $A5; LD ($C001),A; JR to INC.
    constant rom : program_t := (x"21",x"00",x"C0",x"34",x"7E",x"EE",x"A5",
                                x"EA",x"01",x"C0",x"18",x"F7");
begin
    clk <= not clk after 5 ns;
    enable <= ce2 when double_speed else ce;
    bus_busy <= (not rd_n) and (not address(15));
    speed : entity work.speedcontrol port map (
        clk_sys => clk, pause => request, standby_req => request, speedup => '0',
        cart_act => bus_busy, DMA_on => '0', ce => ce, ce_2x => ce2,
        cart_frozen => frozen, refresh => open, ff_on => open);
    cpu : entity work.GBse port map (
        RESET_n => not reset, CLK_n => clk, CLKEN => enable,
        WAIT_n => '1', INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
        M1_n => open, MREQ_n => open, IORQ_n => open, RD_n => rd_n, WR_n => wr_n,
        RFSH_n => open, HALT_n => open, BUSAK_n => open, STOP => open,
        WRITE_CYCLE => open, TSTATE1 => open, TSTATE2 => open, TSTATE3 => open,
        TSTATE4 => open, TSTATEo => open, A => address, DI => din, DO => dout,
        isGBC => '1', SaveStateBus_Din => (others => '0'), SaveStateBus_Adr => state_address,
        SaveStateBus_wren => '0', SaveStateBus_rst => reset, SaveStateBus_Dout => state_word);
    process(all)
    begin
        din <= x"00";
        if address=x"C000" then din <= count;
        elsif address=x"C001" then din <= marker;
        elsif unsigned(address) < rom'length then din <= rom(to_integer(unsigned(address)));
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) and enable = '1' and wr_n = '0' then
            if address=x"C000" then count <= dout; end if;
            if address=x"C001" then marker <= dout; end if;
        end if;
    end process;

    process
        type state_array is array (0 to 63) of std_logic_vector(63 downto 0);
        variable captured : state_array;
        variable count_before, marker_before : std_logic_vector(7 downto 0);
    begin
        wait for 200 ns;
        reset <= '0';
        wait until count = x"05";
        for trial in 1 to 32 loop
            for i in 1 to trial * 13 mod 31 + 1 loop wait until rising_edge(clk); end loop;
            request <= '1';
            wait until frozen = '1';
            wait for 2 ns;
            count_before := count;
            marker_before := marker;
            for i in captured'range loop
                state_address <= std_logic_vector(to_unsigned(i, state_address'length));
                wait until rising_edge(clk); wait for 1 ns;
                captured(i) := state_word;
            end loop;
            wait for 10501 ns;
            assert count = count_before and marker = marker_before and ce='0' and ce2='0'
                report "CPU updated memory or received an enable during standby" severity failure;
            for i in captured'range loop
                state_address <= std_logic_vector(to_unsigned(i, state_address'length));
                wait until rising_edge(clk); wait for 1 ns;
                assert state_word = captured(i) report "CPU state changed during standby" severity failure;
            end loop;
            request <= '0';
            wait until count /= count_before;
            assert unsigned(count)=unsigned(count_before)+1
                report "first INC after wake skipped or repeated counter values" severity failure;
            wait until marker = (count xor x"A5");
        end loop;
        passed <= true;
        wait;
    end process;
end architecture;

library std;
use std.env.all;
entity standby_cpu_tb is end entity;
architecture sim of standby_cpu_tb is
    signal base, double : boolean;
begin
    slow : entity work.standby_cpu_case generic map(false) port map(base);
    fast : entity work.standby_cpu_case generic map(true) port map(double);
    process begin
        wait until base and double;
        report "PASS real GBse counter/marker program through 64 standby/wake cycles at both speeds, 64 CPU state readback addresses per trial";
        finish;
    end process;
    process begin wait for 5 ms; assert false report "CPU standby timeout" severity failure; end process;
end architecture;
