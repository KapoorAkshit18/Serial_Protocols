(* top *)
module top #(

    // ============================================================
    // CLOCK AND UART CONFIGURATION
    // ============================================================
    //
    // CLK:
    //   FPGA system clock frequency in Hz.
    //
    //   Shrike-lite design:
    //       50 MHz = 50,000,000 Hz
    //
    // BAUD_RATE:
    //   UART communication speed.
    //
    //   Common UART setting:
    //       115200 baud
    //
    parameter integer CLK       = 50_000_000,
    parameter integer BAUD_RATE = 115200

)(
    // ============================================================
    // EXTERNAL FPGA PINS
    // ============================================================

    // UART receive input.
    //
    // This signal comes from the external UART transmitter.
    // UART is normally HIGH when no data is being transmitted.
    (* iopad_external_pin *) input  rx,

    // External reset input.
    //
    // This is an asynchronous external signal, so it is
    // synchronized internally before being used by the logic.
    (* iopad_external_pin *) input  rst,

    // FPGA system clock.
    //
    // Expected:
    //       50 MHz
    //
    (* iopad_external_pin *) input  clk,

    // LED output.
    //
    // The LED is controlled by received UART commands.
    (* iopad_external_pin *) output led
);


    // ============================================================
    // UART TIMING CALCULATIONS
    // ============================================================
    //
    // UART does not have a separate clock signal.
    //
    // Instead, the receiver uses the FPGA clock to determine
    // when to sample the RX signal.
    //
    // At 50 MHz:
    //
    //       FPGA clock period = 20 ns
    //
    // For 115200 baud:
    //
    //       bit period = 1 / 115200
    //                  ~= 8.68 us
    //
    // Number of FPGA clock cycles per UART bit:
    //
    //       50,000,000 / 115,200
    //       ~= 434 clocks
    //
    // Therefore the receiver samples approximately every
    // 434 FPGA clock cycles.
    //
    // Integer division is used here. This gives:
    //
    //       CLOCKS_PER_BIT = 434
    //
    // which corresponds to an actual UART rate of approximately
    // 115207 baud. The error is very small and normally acceptable.
    // ============================================================

    localparam integer CLOCKS_PER_BIT = CLK / BAUD_RATE;

    // Half a UART bit period.
    //
    // Used to sample the middle of the start bit.
    //
    // For 115200 baud at 50 MHz:
    //
    //       HALF_BIT = 434 / 2
    //                = 217
    //
    localparam integer HALF_BIT = CLOCKS_PER_BIT / 2;


    // ============================================================
    // UART RECEIVER STATE MACHINE
    // ============================================================
    //
    // The UART receiver has five states:
    //
    // IDLE
    //     Waiting for the RX line to go LOW.
    //
    // RX_START_BIT
    //     Wait until the middle of the start bit and verify
    //     that the line is still LOW.
    //
    // RX_DATA_BITS
    //     Receive the eight data bits.
    //
    // RX_STOP_BIT
    //     Wait for and verify the stop bit.
    //
    // CLEANUP
    //     Generate a one-clock data-valid pulse.
    // ============================================================

    localparam [2:0]

        IDLE         = 3'd0,
        RX_START_BIT = 3'd1,
        RX_DATA_BITS = 3'd2,
        RX_STOP_BIT  = 3'd3,
        CLEANUP      = 3'd4;


    // ============================================================
    // RESET SYNCHRONIZER
    // ============================================================
    //
    // The external reset signal 'rst' is not guaranteed to change
    // at the same time as the FPGA clock.
    //
    // If an asynchronous signal is sampled directly by a flip-flop,
    // the flip-flop can potentially enter a metastable condition.
    //
    // We therefore pass reset through two flip-flops.
    //
    //             external rst
    //                  |
    //                  v
    //              rst_meta
    //                  |
    //                  v
    //              rst_sync
    //
    // Logic inside the FPGA uses rst_sync rather than rst.
    //
    // NOTE:
    // This assumes that rst is ACTIVE HIGH.
    // ============================================================

    reg rst_meta;
    reg rst_sync;

    always @(posedge clk) begin

        // First synchronization stage.
        rst_meta <= rst;

        // Second synchronization stage.
        rst_sync <= rst_meta;

    end


    // ============================================================
    // UART RX SYNCHRONIZER
    // ============================================================
    //
    // The UART RX signal comes from outside the FPGA and therefore
    // is asynchronous to the FPGA clock.
    //
    // We use two flip-flops to synchronize it before the UART
    // state machine uses the signal.
    //
    //             external RX
    //                 |
    //                 v
    //              rx_meta
    //                 |
    //                 v
    //              rx_sync
    //                 |
    //                 v
    //            UART receiver
    //
    // UART idle state is HIGH, therefore both registers are
    // initialized to HIGH during reset.
    // ============================================================

    reg rx_meta;
    reg rx_sync;

    always @(posedge clk) begin

        if (rst_sync) begin

            // UART idle state.
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;

        end
        else begin

            // First synchronization stage.
            rx_meta <= rx;

            // Second synchronization stage.
            rx_sync <= rx_meta;

        end

    end


    // ============================================================
    // UART RECEIVER REGISTERS
    // ============================================================

    // Counts FPGA clock cycles within the current UART bit.
    //
    // At 50 MHz / 115200 baud this counts from approximately
    // 0 to 433.
    //
    // 18 bits provides a maximum count of 262143, which is
    // considerably larger than the required 434.
    reg [17:0] r_Clock_Count;


    // Index of the UART data bit currently being received.
    //
    // UART has eight data bits:
    //
    //       bit 0
    //       bit 1
    //       bit 2
    //       ...
    //       bit 7
    //
    // UART transmits the least-significant bit first.
    reg [2:0] r_Bit_Index;


    // Stores the received eight-bit UART character.
    reg [7:0] r_RX_Byte;


    // Data-valid pulse.
    //
    // This becomes HIGH for one FPGA clock cycle after a valid
    // UART byte has been completely received.
    reg r_RX_DV;


    // Current UART state machine state.
    reg [2:0] r_SM_Main;


    // ============================================================
    // UART RECEIVER
    // ============================================================
    //
    // UART FRAME FORMAT:
    //
    //        START   DATA                         STOP
    //          |      |                            |
    //          v      v                            v
    //
    //        +----+----+----+----+----+----+----+----+----+----+
    //        |  0 | D0 | D1 | D2 | D3 | D4 | D5 | D6 | D7 | 1 |
    //        +----+----+----+----+----+----+----+----+----+----+
    //
    // START:
    //       LOW
    //
    // DATA:
    //       8 bits, LSB first
    //
    // STOP:
    //       HIGH
    //
    // The receiver detects the beginning of the start bit, waits
    // half a bit period, and checks that the line is still LOW.
    //
    // After that, it waits one full bit period between each
    // data-bit sample.
    // ============================================================

    always @(posedge clk) begin

        // --------------------------------------------------------
        // RESET
        // --------------------------------------------------------
        //
        // Reset all UART state.
        // --------------------------------------------------------

        if (rst_sync) begin

            r_Clock_Count <= 18'd0;
            r_Bit_Index   <= 3'd0;
            r_RX_Byte     <= 8'd0;
            r_RX_DV       <= 1'b0;
            r_SM_Main     <= IDLE;

        end

        else begin

            case (r_SM_Main)


                // =================================================
                // IDLE STATE
                // =================================================
                //
                // UART normally stays HIGH while idle.
                //
                // A UART transmission starts when RX changes:
                //
                //       HIGH -> LOW
                //
                // This LOW level represents the start bit.
                // =================================================

                IDLE: begin

                    // No bit timing is active while idle.
                    r_Clock_Count <= 18'd0;

                    // Prepare to receive a new byte.
                    r_Bit_Index <= 3'd0;

                    // data-valid must normally be LOW.
                    r_RX_DV <= 1'b0;


                    // Detect beginning of start bit.
                    if (rx_sync == 1'b0) begin

                        r_SM_Main <= RX_START_BIT;

                    end
                    else begin

                        r_SM_Main <= IDLE;

                    end

                end


                // =================================================
                // RX_START_BIT
                // =================================================
                //
                // We detected a LOW level.
                //
                // It could be a real start bit, but it could also
                // be noise.
                //
                // Therefore we wait HALF_BIT clocks and check
                // the RX signal again.
                //
                // If it is still LOW, we accept it as a valid
                // start bit.
                //
                // Sampling in the middle of the start bit provides
                // better noise and timing tolerance.
                // =================================================

                RX_START_BIT: begin

                    if (r_Clock_Count >= HALF_BIT - 1) begin

                        // Start a new bit-period counter.
                        r_Clock_Count <= 18'd0;


                        // Confirm start bit.
                        if (rx_sync == 1'b0) begin

                            // Valid start bit.
                            // Move to data reception.
                            r_SM_Main <= RX_DATA_BITS;

                        end
                        else begin

                            // The line returned HIGH.
                            // This was probably noise.
                            //
                            // Return to idle and wait for the next
                            // real start bit.
                            r_SM_Main <= IDLE;

                        end

                    end
                    else begin

                        // Continue waiting for the midpoint
                        // of the start bit.
                        r_Clock_Count <= r_Clock_Count + 18'd1;

                    end

                end


                // =================================================
                // RX_DATA_BITS
                // =================================================
                //
                // Receive eight UART data bits.
                //
                // UART sends:
                //
                //       bit 0 first
                //       bit 1
                //       ...
                //       bit 7 last
                //
                // We therefore store each received bit directly
                // into r_RX_Byte[r_Bit_Index].
                //
                // We wait one complete UART bit period between
                // samples.
                // =================================================

                RX_DATA_BITS: begin

                    if (r_Clock_Count >= CLOCKS_PER_BIT - 1) begin

                        // Restart bit timing for the next bit.
                        r_Clock_Count <= 18'd0;


                        // Store received UART bit.
                        //
                        // Example:
                        //
                        // first sample -> r_RX_Byte[0]
                        // second sample -> r_RX_Byte[1]
                        // ...
                        // eighth sample -> r_RX_Byte[7]
                        //
                        r_RX_Byte[r_Bit_Index] <= rx_sync;


                        // Check whether this was bit 7.
                        if (r_Bit_Index == 3'd7) begin

                            // All eight data bits have been received.
                            r_Bit_Index <= 3'd0;

                            // Next we process the stop bit.
                            r_SM_Main <= RX_STOP_BIT;

                        end
                        else begin

                            // Move to the next data bit.
                            r_Bit_Index <= r_Bit_Index + 3'd1;

                        end

                    end
                    else begin

                        // Continue counting clocks for the current
                        // UART data bit.
                        r_Clock_Count <= r_Clock_Count + 18'd1;

                    end

                end


                // =================================================
                // RX_STOP_BIT
                // =================================================
                //
                // A normal UART frame ends with a HIGH stop bit.
                //
                // We wait one complete bit period and then verify
                // that RX is HIGH.
                //
                // If RX is HIGH:
                //
                //       Frame is valid.
                //
                // If RX is LOW:
                //
                //       Framing error.
                // =================================================

                RX_STOP_BIT: begin

                    if (r_Clock_Count >= CLOCKS_PER_BIT - 1) begin

                        // Reset timing counter.
                        r_Clock_Count <= 18'd0;


                        if (rx_sync == 1'b1) begin

                            // Valid stop bit.
                            //
                            // The complete UART byte is now valid.
                            //
                            // Generate a one-clock data-valid pulse.
                            r_RX_DV <= 1'b1;

                            // Go to cleanup.
                            r_SM_Main <= CLEANUP;

                        end
                        else begin

                            // Stop bit was LOW.
                            //
                            // This is a UART framing error.
                            //
                            // Discard the received byte and return
                            // to idle.
                            r_RX_DV <= 1'b0;

                            r_SM_Main <= IDLE;

                        end

                    end
                    else begin

                        // Continue waiting through stop bit.
                        r_Clock_Count <= r_Clock_Count + 18'd1;

                    end

                end


                // =================================================
                // CLEANUP STATE
                // =================================================
                //
                // r_RX_DV is intended to be a ONE-CLOCK pulse.
                //
                // It was asserted in RX_STOP_BIT.
                //
                // On the next clock, clear it and return to IDLE.
                // =================================================

                CLEANUP: begin

                    // Clear data-valid pulse.
                    r_RX_DV <= 1'b0;

                    // Ready for another UART frame.
                    r_SM_Main <= IDLE;

                end


                // =================================================
                // DEFAULT STATE
                // =================================================
                //
                // Safety recovery.
                //
                // If the state machine somehow enters an invalid
                // state, return it to a known idle condition.
                // =================================================

                default: begin

                    r_Clock_Count <= 18'd0;
                    r_Bit_Index   <= 3'd0;
                    r_RX_Byte     <= 8'd0;
                    r_RX_DV       <= 1'b0;
                    r_SM_Main     <= IDLE;

                end

            endcase

        end

    end


    // ============================================================
    // LED CONTROL
    // ============================================================
    //
    // The LED responds to specific UART commands.
    //
    // Received byte:
    //
    //       0xAB -> LED ON
    //
    //       0xFF -> LED OFF
    //
    // Any other byte:
    //
    //       LED keeps its previous state.
    //
    // The LED only changes when r_RX_DV is HIGH, meaning that a
    // complete and valid UART frame has been received.
    // ============================================================

    reg led_internal;


    // Connect internal LED register to the physical LED pin.
    assign led = led_internal;

//temporary logic

always @(posedge clk) begin
    if (rst_sync) begin
        led_internal <= 1'b0;
    end
    else if (r_RX_DV) begin
        led_internal <= ~led_internal;
    end
end





//
//     always @(posedge clk) begin
//
//         // --------------------------------------------------------
//         // RESET
//         // --------------------------------------------------------
//         //
//         // Turn LED OFF during reset.
//         // --------------------------------------------------------
//
//         if (rst_sync) begin
//
//             led_internal <= 1'b0;
//
//         end
//
//         // --------------------------------------------------------
//         // VALID UART DATA
//         // --------------------------------------------------------
//         //
//         // Only examine the received byte when the UART receiver
//         // indicates that a complete valid byte is available.
//         // --------------------------------------------------------
//
//         else if (r_RX_DV) begin
//
//             case (r_RX_Byte)
//
//
//                 // ------------------------------------------------
//                 // 0xAB = LED ON
//                 // ------------------------------------------------
//
//                 8'hAB: begin
//
//                     led_internal <= 1'b1;
//
//                 end
//
//
//                 // ------------------------------------------------
//                 // 0xFF = LED OFF
//                 // ------------------------------------------------
//
//                 8'hFF: begin
//
//                     led_internal <= 1'b0;
//
//                 end
//
//
//                 // ------------------------------------------------
//                 // Any other byte
//                 //
//                 // Do not change LED state.
//                 // ------------------------------------------------
//
//                 default: begin
//
//                     led_internal <= led_internal;
//
//                 end
//
//             endcase
//
//         end
//
//     end
//
endmodule
