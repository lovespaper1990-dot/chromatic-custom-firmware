library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pMultiPortPSRAM.all;

entity snapshot_arbiter_tb is end entity;
architecture test of snapshot_arbiter_tb is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal request : tRAMIn_request := (others => '0');
    signal rnw : tRAMIn_RnW := (others => '0');
    signal addr : tRAMIn_addr;
    signal data : tRAMIn_din;
    signal length : tRAMIn_burst_length := (others => to_unsigned(8, 11));
    signal advance : tRAMOut_writeNext;
    signal done : tRAMOut_done;
    signal valid : tRAMOut_dout_valid;
    signal dout : std_logic_vector(15 downto 0);
    signal completed : natural range 0 to 12 := 0;
    function pattern(channel, beat : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(16#8210# + channel*256 + beat*17, 16));
    end function;
begin
    clk <= not clk after 5 ns;
    dut: entity work.MultiPortRamCtrl port map(
        clk, clk, rst, request, rnw, addr, data, length, advance, done, valid,
        open, dout, open, open, open, open);

    ports: for i in 0 to 5 generate
        signal beat : integer range 0 to 3 := 0;
    begin
        addr(i) <= std_logic_vector(to_unsigned(16#40000#+8*i,23)) when i=5 else
                   std_logic_vector(to_unsigned(8*i,23));
        data(i) <= pattern(i,beat);
        process(clk)
        begin
            if rising_edge(clk) then
                if valid(i)='1' then
                    assert dout=pattern(i,beat)
                        report "incorrect PSRAM data or grant for channel " & integer'image(i)
                        severity failure;
                end if;
                if done(i)='1' then beat<=0;
                elsif advance(i)='1' or valid(i)='1' then beat<=beat+1; end if;
            end if;
        end process;
    end generate;
    process(clk)
    begin
        if rising_edge(clk) then
            for i in 0 to 5 loop
                if done(i)='1' then completed<=completed+1; end if;
            end loop;
        end if;
    end process;
    process
    begin
        wait until falling_edge(clk);
        rst<='0'; request<=(others=>'1');
        wait until falling_edge(clk); request<=(others=>'0');
        wait until completed=6 for 10 us;
        assert completed=6 report "a queued write starved" severity failure;
        wait until falling_edge(clk); rnw<=(others=>'1'); request<=(others=>'1');
        wait until falling_edge(clk); request<=(others=>'0');
        wait until completed=12 for 10 us;
        assert completed=12 report "a queued read starved" severity failure;
        report "PASS: six concurrent PSRAM clients, grants, data beats and completion routing";
        std.env.finish;
    end process;
end architecture;
