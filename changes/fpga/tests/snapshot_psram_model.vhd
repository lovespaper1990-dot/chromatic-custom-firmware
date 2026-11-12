-- A four-beat, 16-bit backing RAM. The production arbiter is tested unchanged.
-- The pins are present so the same production component binding can be used.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity PSRAMController is
    generic (ISSIMU : boolean := true);
    port (
        clk_sys, clk_fsys, rst, req_read, req_write : in std_logic;
        addr : in std_logic_vector(22 downto 0);
        din : in std_logic_vector(15 downto 0);
        burst_length : in unsigned(10 downto 0);
        ready, writeNext, done, dout_valid : out std_logic;
        dout : out std_logic_vector(15 downto 0);
        psram_clk, psram_cs_n : out std_logic;
        psram_rwds : inout std_logic;
        psram_dq : inout std_logic_vector(7 downto 0)
    );
end entity;

architecture sim of PSRAMController is
    type memory_t is array(0 to 23) of std_logic_vector(15 downto 0);
    signal mem : memory_t;
    signal first : integer range 0 to 20 := 0;
    signal part : integer range 0 to 3 := 0;
    signal active, reading : boolean := false;
begin
    ready <= '1' when not active else '0';
    writeNext <= '1' when active and not reading and part < 3 else '0';
    dout_valid <= '1' when active and reading else '0';
    done <= '1' when active and part = 3 else '0';
    dout <= mem(first + part);

    process(clk_sys)
        variable offset : natural;
    begin
        if rising_edge(clk_sys) then
            if rst = '1' then
                active <= false;
            elsif not active and (req_read = '1' or req_write = '1') then
                assert burst_length = 8 and addr(2 downto 0) = "000" severity failure;
                offset := to_integer(unsigned(addr));
                if offset >= 16#40000# then offset := offset - 16#40000#; end if;
                assert offset < 48 severity failure;
                first <= offset / 2;
                reading <= req_read = '1';
                active <= true;
                part <= 0;
            elsif active then
                if not reading then mem(first + part) <= din; end if;
                if part = 3 then active <= false;
                else part <= part + 1; end if;
            end if;
        end if;
    end process;
end architecture;
