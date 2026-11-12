-- Exercise the real Gameboy_MiSTer state engine with Chromatic's ROM-only
-- wiring and a variable-latency backing store. From the FPGA repository:
-- ghdl -a --std=08 esp32t/src/rtl/EMU/CORE/bus_savestates.vhd \
--   esp32t/src/rtl/EMU/CORE/gb_savestates.vhd tests/savestate_engine_tb.vhd
-- ghdl --elab-run --std=08 savestate_engine_tb --assert-level=error
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pBus_savestates.all;

entity savestate_engine_tb is
end;

architecture test of savestate_engine_tb is
    subtype byte_t is std_logic_vector(7 downto 0);
    subtype word_t is std_logic_vector(63 downto 0);
    type sizes_t is array(natural range <>) of natural;
    type bytes_t is array(natural range <>) of byte_t;
    type words_t is array(natural range <>) of word_t;
    constant bank_sizes : sizes_t(0 to 4) := (32768, 16384, 160, 128, 512);
    constant slot_base : natural := 16#3800000#;
    constant word_count : natural := 6309; -- header, 64 registers, then 49952 bytes

    signal clk : std_logic := '0';
    signal abort_state, reset_in, save, load, vsync, ce, corrupt, bad_header : std_logic := '0';
    signal busy, asleep, saving, loading, reset_out, load_done : std_logic;
    signal reg_addr : std_logic_vector(BUS_busadr-1 downto 0);
    signal reg_input, reg_output : word_t;
    signal reg_write, reg_reset : std_logic;
    signal ram_read : bytes_t(0 to 4);
    signal ram_addr : std_logic_vector(19 downto 0);
    signal ram_enable : std_logic_vector(4 downto 0);
    signal ram_write : byte_t;
    signal store_input, store_output : word_t;
    signal store_addr : std_logic_vector(25 downto 0);
    signal store_read, store_request, store_done : std_logic := '0';
    signal enables : byte_t;
    signal writes, reads, restored_regs : natural := 0;
    signal restored_bytes : sizes_t(0 to 4) := (others => 0);

    function register_seed(address : natural) return word_t is
    begin
        return x"01234567A5F0C33C" xor
               (std_logic_vector(to_unsigned(address * 1291, 32)) &
                std_logic_vector(to_unsigned(address * 937, 32)));
    end;

    function byte_seed(bank, address : natural) return byte_t is
    begin
        -- The ROM-only port ties cartridge RAM reads low, including its
        -- 512-byte MBC2 placeholder in the upstream file format.
        if bank = 4 then return x"00"; end if;
        return std_logic_vector(to_unsigned(
            (address * 53 + (address / 256) * 11 + bank * 29 + 5) mod 256, 8));
    end;

    function expected_word(index : natural) return word_t is
        variable address : natural;
        variable packed : word_t;
    begin
        if index = 0 then return x"0000B0CA00000001"; end if;
        if index <= 64 then return register_seed(index - 1); end if;
        address := (index - 65) * 8;
        for bank in bank_sizes'range loop
            if address < bank_sizes(bank) then
                for lane in 0 to 7 loop
                    packed(lane*8+7 downto lane*8) := byte_seed(bank, address + lane);
                end loop;
                return packed;
            end if;
            address := address - bank_sizes(bank);
        end loop;
        assert false report "Out-of-range state word" severity failure;
        return (others => 'X');
    end;
begin
    clk <= not clk after 5 ns;

    dut: entity work.gb_savestates port map (
        clk => clk, reset_in => reset_in, abort_state => abort_state, reset_out => reset_out, load_done => load_done,
        increaseSSHeaderCount => '0', save => save, load => load,
        savestate_address => slot_base, savestate_busy => busy, cart_ram_size => x"00",
        lcd_vsync => vsync, BUS_Din => reg_input, BUS_Adr => reg_addr,
        BUS_wren => reg_write, BUS_rst => reg_reset, BUS_Dout => reg_output,
        loading_savestate => loading, saving_savestate => saving,
        sleep_savestate => asleep, clock_ena_in => ce,
        Save_RAMAddr => ram_addr, Save_RAMWrEn => ram_enable, Save_RAMWriteData => ram_write,
        Save_RAMReadData_WRAM => ram_read(0), Save_RAMReadData_VRAM => ram_read(1),
        Save_RAMReadData_ORAM => ram_read(2), Save_RAMReadData_ZRAM => ram_read(3),
        Save_RAMReadData_CRAM => x"00", bus_out_Din => store_input, bus_out_Dout => store_output,
        bus_out_Adr => store_addr, bus_out_rnw => store_read, bus_out_ena => store_request,
        bus_out_be => enables, bus_out_done => store_done);

    registers: process(clk)
        variable data : words_t(0 to 63);
        variable initialized : boolean := false;
    begin
        if falling_edge(clk) then
            if not initialized or corrupt = '1' then
                for i in data'range loop
                    data(i) := register_seed(i);
                    if corrupt = '1' then data(i) := not data(i); end if;
                end loop;
                initialized := true;
            end if;
            if reg_write = '1' then
                assert to_integer(unsigned(reg_addr)) = restored_regs severity failure;
                assert reg_input = register_seed(restored_regs) severity failure;
                data(restored_regs) := reg_input;
                restored_regs <= restored_regs + 1;
            end if;
            reg_output <= data(to_integer(unsigned(reg_addr)));
        end if;
    end process;

    banks: for bank in bank_sizes'range generate
        memory: process(clk)
            variable data : bytes_t(0 to bank_sizes(bank)-1);
            variable initialized : boolean := false;
            variable address : natural;
        begin
            if rising_edge(clk) then
                if not initialized or corrupt = '1' then
                    for i in data'range loop
                        data(i) := byte_seed(bank, i);
                        if corrupt = '1' then data(i) := not data(i); end if;
                    end loop;
                    initialized := true;
                end if;
                address := to_integer(unsigned(ram_addr));
                ram_read(bank) <= data(address mod data'length); -- synchronous read
                if ram_enable(bank) = '1' then
                    assert address = restored_bytes(bank) report "RAM address skipped" severity failure;
                    assert ram_write = byte_seed(bank, address) report "RAM data differs" severity failure;
                    data(address) := ram_write;
                    restored_bytes(bank) <= restored_bytes(bank) + 1;
                end if;
                if load_done = '1' then
                    for i in data'range loop
                        assert data(i) = byte_seed(bank, i) report "Restored bank mismatch" severity failure;
                    end loop;
                end if;
            end if;
        end process;
    end generate;

    -- Capture each request once. The response delay varies from 1 to 8
    -- cycles, and read data remains on the bus until the next acknowledged read.
    backing_store: process(clk)
        variable slot : words_t(0 to word_count-1);
        variable pending : boolean := false;
        variable remaining, index, address : natural := 0;
        variable read_request : std_logic;
        variable data : word_t;
    begin
        if rising_edge(clk) then
            store_done <= '0';
            if store_request = '1' then
                assert not pending and asleep = '1' report "Overlapping or unpaused request" severity failure;
                address := to_integer(unsigned(store_addr));
                assert address >= slot_base and address < slot_base + word_count*2
                    and address mod 2 = 0 report "Bad slot address" severity failure;
                index := (address - slot_base)/2;
                read_request := store_read;
                data := store_input;
                if read_request = '0' then
                    assert index = (writes + 1) mod word_count report "Header must commit last" severity failure;
                    assert data = expected_word(index) report "Bad state word " & integer'image(index) severity failure;
                    if index = 0 then
                        assert enables = x"F0" severity failure;
                    else
                        assert enables = x"FF" severity failure;
                    end if;
                elsif bad_header = '0' then
                    assert index = reads-1 report "Unexpected restore address" severity failure;
                else
                    assert index = 0 and reads = 0 report "Read past invalid header" severity failure;
                end if;
                remaining := index mod 8 + 1;
                pending := true;
            elsif pending then
                assert to_integer(unsigned(store_addr)) = address and store_read = read_request
                    report "Request changed while waiting for ACK" severity failure;
                if remaining = 1 then
                    if read_request = '0' then
                        -- Chromatic's mailbox stores the entire 64-bit word.
                        slot(index) := data;
                        writes <= writes + 1;
                    else
                        store_output <= slot(index);
                        if bad_header = '1' then store_output <= (others => '0'); end if;
                        reads <= reads + 1;
                    end if;
                    store_done <= '1';
                    pending := false;
                else
                    remaining := remaining - 1;
                end if;
            end if;
        end if;
    end process;

    stimulus: process
        procedure tick is begin wait until falling_edge(clk); wait for 1 ns; end;
    begin
        tick; reset_in <= '1'; tick;
        assert reset_out = '1' and reg_reset = '1' severity failure;
        reset_in <= '0'; ce <= '1'; save <= '1'; tick; save <= '0';
        for i in 1 to 12 loop tick; end loop;
        assert busy = '1' and asleep = '0' and writes = 0 report "Saved before VBlank" severity failure;
        vsync <= '1'; tick; vsync <= '0';
        for i in 1 to 115 loop tick; end loop;
        assert asleep = '1' and saving = '0' and writes = 0 report "Missed clock settle" severity failure;
        ce <= '0';
        wait until busy = '0'; tick;
        assert writes = word_count and asleep = '0' report "Incomplete capture" severity failure;

        corrupt <= '1'; tick; corrupt <= '0';
        bad_header <= '1'; load <= '1'; tick; load <= '0';
        wait until busy = '0'; tick;
        assert reads = 1 and restored_regs = 0 and load_done = '0' severity failure;

        bad_header <= '0'; load <= '1'; tick; load <= '0';
        wait until load_done = '1'; tick; tick;
        assert reads = word_count + 1 and restored_regs = 64 and asleep = '0' and busy = '0' severity failure;
        assert restored_bytes = bank_sizes report "Incomplete restored RAM" severity failure;
        -- Abort while the core waits for a VBlank and while a restore waits
        -- for clocks to settle. Neither case may leave the emulation paused.
        ce <= '1'; save <= '1'; tick; save <= '0'; tick;
        assert busy = '1' and writes = word_count severity failure;
        abort_state <= '1'; tick; abort_state <= '0'; tick;
        assert busy = '0' and asleep = '0' and writes = word_count severity failure;
        load <= '1'; tick; load <= '0'; tick;
        assert busy = '1' and asleep = '1' severity failure;
        abort_state <= '1'; tick; abort_state <= '0'; tick;
        assert busy = '0' and asleep = '0' and ram_enable = "00000" and load_done = '0' severity failure;
        report "PASS: 6309 words, 64 registers and five memory regions; delayed ACK, invalid header and abort recovery";
        finish;
    end process;

    watchdog: process
    begin
        wait for 5 ms;
        assert false report "State engine timed out" severity failure;
    end process;
end;
