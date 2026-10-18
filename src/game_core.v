`default_nettype none

module tt_um_peakpachi_flappy_birby (
    input  wire [7:0] ui_in,    // dedicated inputs
    output wire [7:0] uo_out,   // dedicated outputs
    input  wire [7:0] uio_in,   // bidirectional pins, input path
    output wire [7:0] uio_out,  // bidirectional pins, output path
    output wire [7:0] uio_oe,   // bidirectional pins, 1 = drive
    input  wire       ena,      // high when the design is powered, ignore
    input  wire       clk,      // clock
    input  wire       rst_n     // reset, active low
);
    wire        hsync, vsync, active, frame;
    wire [9:0]  x, y;
    wire [5:0]  rgb;
    wire        speaker;

    vga_sync vga (.clk(clk), .rst_n(rst_n), .hsync(hsync), .vsync(vsync), .active(active), .x(x), .y(y), .frame(frame));

    game_core core (
        .clk(clk), .rst_n(rst_n),
        .left(ui_in[0]), // Switched from ui_in[2] to ui_in[0] (Pin 1)
        .x(x), .y(y), .active(active), .frame(frame),
        .rgb(rgb),
        .speaker(speaker) 
    );

    // TinyVGA PMOD pin order
    assign uo_out = {hsync, rgb[0], rgb[2], rgb[4], vsync, rgb[1], rgb[3], rgb[5]};
    
    // Route speaker to pin 7
    assign uio_out = {speaker, 7'b0000000};
    assign uio_oe  = {1'b1,    7'b0000000}; 

    // Unused wires (updated to track ui_in[2] instead of ui_in[0])
    wire _unused = &{ena, uio_in, ui_in[7:3], ui_in[2], ui_in[1], 1'b0};
    
endmodule

`default_nettype none

module game_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       left,
    input  wire [9:0] x,
    input  wire [9:0] y,
    input  wire       active,
    input  wire       frame,
    output wire [5:0] rgb,
    output wire       speaker
);

    // BIRD_X must be a multiple of 32 (sprite uses x[9:5]/x[4:2] directly)
    localparam [9:0] BIRD_X = 10'd160;
    localparam [9:0] BIRD_W = 10'd32;
    localparam [9:0] BIRD_H = 10'd32;
    localparam [9:0] PIPE_W = 10'd48;
    localparam [9:0] GAP_H  = 10'd130;

    // Pre-calculated boundaries to save combinational adders/subtractors
    localparam [9:0] HIT_LEFT  = BIRD_X - PIPE_W;
    localparam [9:0] HIT_RIGHT = BIRD_X + BIRD_W;
    localparam [9:0] GAP_BOT   = GAP_H - BIRD_H;

    // 1. Frame throttle (17 of every 20 frames)
    reg [4:0] throttle_count;
    reg       game_tick;
    wire thr_wrap = (throttle_count == 5'd19);
    wire thr_skip = thr_wrap | (throttle_count == 5'd6) | (throttle_count == 5'd13);
    
    always @(posedge clk) begin
        if (!rst_n) begin
            throttle_count <= 5'd0;
            game_tick      <= 1'b0;
        end else begin
            game_tick <= frame & ~thr_skip;
            if (frame) throttle_count <= thr_wrap ? 5'd0 : throttle_count + 5'd1;
        end
    end

    // 2. Button handling (Shift register optimized)
    reg db_s1, db_s2, db_clean, flap_last;
    always @(posedge clk) begin
        if (!rst_n) begin
            {flap_last, db_clean, db_s2, db_s1} <= 4'b0;
        end else begin
            {db_s2, db_s1} <= {db_s1, left};
            if (frame) db_clean <= db_s2;
            flap_last <= db_clean;
        end
    end
    wire jump_pulse = db_clean & ~flap_last;

    reg jump_pending;
    always @(posedge clk) begin
        if (!rst_n)          jump_pending <= 1'b0;
        else if (jump_pulse) jump_pending <= 1'b1;
        else if (game_tick)  jump_pending <= 1'b0;
    end

    // 3. Free-running RNG
    reg [7:0] rand_y;
    always @(posedge clk) rand_y <= rand_y + 8'd7;

    // 4. State
    reg [8:0]      bird_y_r;
    reg signed [4:0] velocity;
    reg [9:0] pipe1_x, pipe2_x;
    reg [7:0] pipe1_gap_y, pipe2_gap_y;
    reg       pipe1_passed, pipe2_passed;
    reg       pipe1_move, pipe2_move;
    reg       pipe1_dir,  pipe2_dir;
    reg [3:0] score_tens, score_ones;
    reg [3:0] h_score_tens, h_score_ones;
    reg       game_over;
    reg [4:0] invert_counter;
    reg       invert_mode;

    wire [9:0] bird_y = {1'b0, bird_y_r};

    // clamp bits logic
    wire floor_hit = &bird_y_r[8:6]; // >= 448
    wire [9:0] next_y  = bird_y + {{5{velocity[4]}}, velocity};
    wire [8:0] y_clamp = next_y[9] ? 9'd0 : (next_y > 10'd448) ? 9'd448 : next_y[8:0];

    wire [9:0] pipe_speed = 10'd3 + {6'd0, score_tens};
    wire p1_wrap = (pipe1_x < pipe_speed);
    wire p2_wrap = (pipe2_x < pipe_speed);

    wire p1_pass = !pipe1_passed && (pipe1_x < HIT_LEFT);
    wire p2_pass = !pipe2_passed && (pipe2_x < HIT_LEFT);
    
    // Concatenated comparator saves LUTs vs standard complex boolean logic
    wire score_gt_high = {score_tens, score_ones} > {h_score_tens, h_score_ones};
    wire game_restart  = game_over && floor_hit && jump_pending;

    // 5. Collision (Optimized limits)
    wire [9:0] gap1_10 = {2'b00, pipe1_gap_y};
    wire [9:0] gap2_10 = {2'b00, pipe2_gap_y};

    wire crash1 = (pipe1_x < HIT_RIGHT) && (pipe1_x > HIT_LEFT) &&
                  ((bird_y < gap1_10) || (bird_y > gap1_10 + GAP_BOT));
    wire crash2 = (pipe2_x < HIT_RIGHT) && (pipe2_x > HIT_LEFT) &&
                  ((bird_y < gap2_10) || (bird_y > gap2_10 + GAP_BOT));

    // 6. Main game loop
    wire init = !rst_n || (game_tick && game_restart);

    always @(posedge clk) begin
        if (init) begin
            bird_y_r       <= 9'd240;
            velocity       <= 5'sd0;
            {pipe1_x, pipe2_x} <= {10'd640, 10'd960};
            {pipe1_gap_y, pipe2_gap_y} <= {8'd160, 8'd220};
            {pipe1_passed, pipe2_passed} <= 2'b0;
            {pipe1_move, pipe2_move} <= 2'b0;
            {pipe1_dir, pipe2_dir} <= 2'b0;
            {score_tens, score_ones} <= 8'd0;
            invert_counter <= 5'd0;
            invert_mode    <= 1'b0;
            game_over      <= 1'b0;
        end else if (game_tick) begin
            if (crash1 || crash2 || floor_hit) game_over <= 1'b1;
            bird_y_r <= y_clamp;

            if (game_over) begin
                if (velocity != 5'sd15) velocity <= velocity + 5'sd1;
            end else begin
                if (jump_pending)
                    velocity <= invert_mode ? 5'sd8 : -5'sd8;
                else if (invert_mode) begin
                    if (velocity != -5'sd15) velocity <= velocity - 5'sd1;
                end else begin
                    if (velocity != 5'sd15)  velocity <= velocity + 5'sd1;
                end

                // Pipe 1
                if (p1_wrap) begin
                    pipe1_x      <= 10'd640;
                    pipe1_gap_y  <= 8'd50 + {1'b0, rand_y[6:0] ^ bird_y_r[6:0]};
                    pipe1_passed <= 1'b0;
                    pipe1_move   <= ((bird_y_r[2:1] ^ score_ones[1:0]) == 2'd0);
                    pipe1_dir    <= bird_y_r[3];
                end else begin
                    pipe1_x <= pipe1_x - pipe_speed;
                    if (pipe1_move) begin
                        pipe1_gap_y <= pipe1_dir ? pipe1_gap_y - 8'd1 : pipe1_gap_y + 8'd1;
                        if      (pipe1_gap_y >= 8'd218) pipe1_dir <= 1'b1;
                        else if (pipe1_gap_y <= 8'd52)  pipe1_dir <= 1'b0;
                    end
                end

                // Pipe 2
                if (p2_wrap) begin
                    pipe2_x      <= 10'd640;
                    pipe2_gap_y  <= 8'd50 + {1'b0, rand_y[6:0] ^ ~bird_y_r[6:0]};
                    pipe2_passed <= 1'b0;
                    pipe2_move   <= ((bird_y_r[2:1] ^ score_ones[1:0]) == 2'd3);
                    pipe2_dir    <= bird_y_r[4];
                end else begin
                    pipe2_x <= pipe2_x - pipe_speed;
                    if (pipe2_move) begin
                        pipe2_gap_y <= pipe2_dir ? pipe2_gap_y - 8'd1 : pipe2_gap_y + 8'd1;
                        if      (pipe2_gap_y >= 8'd218) pipe2_dir <= 1'b1;
                        else if (pipe2_gap_y <= 8'd52)  pipe2_dir <= 1'b0;
                    end
                end

                // Score & invert tracker
                if (p1_pass || p2_pass) begin
                    if (score_ones == 4'd9) begin
                        score_ones <= 4'd0;
                        if (score_tens != 4'd9) score_tens <= score_tens + 4'd1;
                    end else score_ones <= score_ones + 4'd1;

                    if (invert_counter == 5'd24) begin
                        invert_counter <= 5'd0;
                        invert_mode    <= ~invert_mode;
                    end else invert_counter <= invert_counter + 5'd1;

                    if (p1_pass) pipe1_passed <= 1'b1;
                    if (p2_pass) pipe2_passed <= 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            {h_score_tens, h_score_ones} <= 8'd0;
        end else if (game_tick && score_gt_high) begin
            {h_score_tens, h_score_ones} <= {score_tens, score_ones};
        end
    end

    // 7. Bird sprite
    wire [9:0] by_d = y - bird_y; 
    wire in_bird_box = (x[9:5] == 5'd5) && (by_d[9:5] == 5'd0);
    wire [2:0] bx = x[4:2];
    wire [2:0] by = by_d[4:2] ^ {3{invert_mode}};

    reg [2:0] p_color;
    always @(*) begin
        p_color = 3'd0;
        if (in_bird_box) begin
            case (by)
                3'd0: if (bx == 4) p_color = 1; else if (bx == 5) p_color = 2;
                3'd1: if (bx == 3) p_color = 3; else if (bx == 4 || bx == 5) p_color = 1; else if (bx == 6) p_color = 2;
                3'd2: if (bx == 3 || bx == 4 || bx == 6) p_color = 1; else if (bx == 5) p_color = 4;
                3'd3: if (bx == 0 || bx == 4 || bx == 5) p_color = 1; else if (bx == 1 || bx == 2) p_color = 2; else if (bx == 3) p_color = 3; else if (bx == 6) p_color = 5; else if (bx == 7) p_color = 6;
                3'd4: if (bx == 0 || bx == 5) p_color = 3; else if (bx >= 1 && bx <= 3) p_color = 1; else if (bx == 4) p_color = 2;
                3'd5: if (bx == 1 || bx == 4) p_color = 3; else if (bx == 2) p_color = 1; else if (bx == 3 || bx == 5) p_color = 2;
                3'd6: if (bx == 2 || bx == 3) p_color = 3; else if (bx == 4) p_color = 1;
                default: p_color = 3'd0;
            endcase
        end
    end
    wire bird_hit = (p_color != 3'd0);

    // Pipes (10-bit wrap trick avoids an 11-bit subtractor)
    wire in_p1x = ((x - pipe1_x) < PIPE_W);
    wire in_p2x = ((x - pipe2_x) < PIPE_W);
    wire pipe_hit = (in_p1x && ((y < gap1_10) || (y >= gap1_10 + GAP_H))) ||
                    (in_p2x && ((y < gap2_10) || (y >= gap2_10 + GAP_H)));

    // 8. Shared glyph renderer (Score digits + ":(" )
    wire in_srow   = (y >= 10'd32) && (y < 10'd72);
    wire in_tens   = in_srow && (x >= 10'd292) && (x < 10'd316);
    wire in_ones   = in_srow && (x >= 10'd324) && (x < 10'd348);
    wire in_h_tens = in_srow && (x >= 10'd560) && (x < 10'd584);
    wire in_h_ones = in_srow && (x >= 10'd592) && (x < 10'd616);
    
    // Centered window for two characters: 64 pixels wide
    wire in_sad    = game_over && (x >= 10'd288) && (x < 10'd352) && (y >= 10'd224) && (y < 10'd264);
    wire is_colon  = (x < 10'd320);

    wire [3:0] dig = in_tens ? score_tens : in_ones ? score_ones : in_h_tens ? h_score_tens : h_score_ones;

    reg [3:0] glyph;
    always @(*) begin
        if (in_sad) begin
            glyph = is_colon ? 4'd10 : 4'd11;
        end else glyph = dig;
    end

    // ROM inferred font map
    reg [14:0] font_rom [0:11];
    initial begin
        font_rom[0] = 15'b111_101_101_101_111; font_rom[1]  = 15'b010_110_010_010_111; // 0, 1
        font_rom[2] = 15'b111_001_111_100_111; font_rom[3]  = 15'b111_001_111_001_111; // 2, 3
        font_rom[4] = 15'b101_101_111_001_001; font_rom[5]  = 15'b111_100_111_001_111; // 4, 5
        font_rom[6] = 15'b111_100_111_101_111; font_rom[7]  = 15'b111_001_001_001_001; // 6, 7
        font_rom[8] = 15'b111_101_111_101_111; font_rom[9]  = 15'b111_101_111_001_111; // 8, 9
        font_rom[10]= 15'b000_010_000_010_000; font_rom[11] = 15'b010_100_100_100_010; // :, (
    end
    wire [14:0] dfont = font_rom[(glyph > 4'd11) ? 4'd0 : glyph];

    wire [2:0] gy = {~y[5], y[4:3]};
    reg  [2:0] drow;
    always @(*) begin
        case (gy)
            3'd0: drow = dfont[14:12]; 3'd1: drow = dfont[11:9];
            3'd2: drow = dfont[8:6];   3'd3: drow = dfont[5:3];
            3'd4: drow = dfont[2:0];   default: drow = 3'b000;
        endcase
    end

    wire [4:0] dx = x[4:0] - ((in_tens || in_ones) ? 5'd4 : 5'd16);
    wire lit = (dx[4:3] == 2'd0) ? drow[2] : (dx[4:3] == 2'd1) ? drow[1] : (dx[4:3] == 2'd2) ? drow[0] : 1'b0;

    wire draw_sad    = in_sad && lit;
    wire score_hit   = lit && (((score_tens   != 4'd0) && in_tens)   || in_ones);
    wire h_score_hit = lit && (((h_score_tens != 4'd0) && in_h_tens) || in_h_ones);
    wire any_text    = draw_sad | score_hit | h_score_hit;

    // 9. Colours
    reg [5:0] bird_rgb;
    always @(*) begin
        case (p_color)
            3'd1: bird_rgb = 6'b11_11_00; 3'd2: bird_rgb = 6'b11_11_01;
            3'd3: bird_rgb = 6'b11_10_00; 3'd5: bird_rgb = 6'b10_00_00;
            3'd6: bird_rgb = 6'b11_00_00; default: bird_rgb = 6'b00_00_00; 
        endcase
    end

    wire [5:0] bg_color   = invert_mode ? 6'b00_00_00 : 6'b00_10_11;
    wire [5:0] pipe_color = invert_mode ? 6'b11_11_11 : 6'b00_11_00;
    wire [5:0] text_color = (h_score_hit && !draw_sad && !score_hit) ? 6'b11_10_00 : 6'b11_11_11;

    assign rgb = !active   ? 6'b00_00_00 :
                 any_text  ? text_color  :
                 bird_hit  ? bird_rgb    :
                 pipe_hit  ? pipe_color  :
                 game_over ? 6'b01_00_00 : bg_color;

    // 10. Audio sequencer
    reg        audio_active;
    reg [3:0]  index;
    reg [1:0]  tick;
    reg [2:0]  step;
    reg        game_over_last, tens_inc, h_score_beaten;

    wire last_index = (index == 4'd2) || (index == 4'd6) || (index == 4'd10);

    // Audio Sequence ROM Memory mapping
    reg [18:0] audio_rom [0:10];
    initial begin
        audio_rom[0] = {16'd35815, 3'd0}; audio_rom[1] = {16'd40191, 3'd0}; audio_rom[2] = {16'd42661, 3'd1};
        audio_rom[3] = {16'd23899, 3'd1}; audio_rom[4] = {16'd18967, 3'd1}; audio_rom[5] = {16'd15942, 3'd1};
        audio_rom[6] = {16'd11949, 3'd5}; audio_rom[7] = {16'd35815, 3'd3}; audio_rom[8] = {16'd37992, 3'd3};
        audio_rom[9] = {16'd40191, 3'd3}; audio_rom[10]= {16'd42661, 3'd7};
    end

    wire [15:0] hp_m1;
    wire [2:0]  length_m1;
    assign {hp_m1, length_m1} = audio_rom[(index > 4'd10) ? 4'd10 : index];

    always @(posedge clk) begin
        if (!rst_n) begin
            game_over_last <= 1'b0;
            tens_inc       <= 1'b0;
        end else begin
            game_over_last <= game_over;
            tens_inc <= game_tick && !game_over && (p1_pass || p2_pass) && (score_ones == 4'd9) && (score_tens != 4'd9);
        end
    end

    wire crash_pulse      = game_over & ~game_over_last;
    wire score_10_pulse   = tens_inc && !game_over;
    wire is_new_high      = score_gt_high && (score_tens | score_ones) != 0;
    wire high_score_pulse = is_new_high && !h_score_beaten && !game_over;

    always @(posedge clk) begin
        if (!rst_n || game_restart) h_score_beaten <= 1'b0;
        else if (high_score_pulse)  h_score_beaten <= 1'b1;
    end

    wire last_step      = (step == length_m1);
    wire sixteenth_done = frame && (tick == 2'd2);
    wire note_done      = sixteenth_done && last_step;
    wire gap            = last_step && (tick == 2'd2);

    always @(posedge clk) begin
        if (!rst_n) begin
            tick <= 2'd0; step <= 3'd0; index <= 4'd0; audio_active <= 1'b0;
        end else begin
            if (crash_pulse) begin
                index <= 4'd7; audio_active <= 1'b1; tick <= 2'd0; step <= 3'd0;
            end else if (high_score_pulse) begin
                index <= 4'd3; audio_active <= 1'b1; tick <= 2'd0; step <= 3'd0;
            end else if (score_10_pulse) begin
                index <= 4'd6; audio_active <= 1'b1; tick <= 2'd0; step <= 3'd0;
            end else if (jump_pulse && !game_over) begin
                index <= 4'd0; audio_active <= 1'b1; tick <= 2'd0; step <= 3'd0;
            end else if (audio_active) begin
                if (frame) tick <= sixteenth_done ? 2'd0 : tick + 2'd1;
                if (note_done) begin
                    step <= 3'd0;
                    if (last_index) audio_active <= 1'b0;
                    else            index <= index + 4'd1;
                end else if (sixteenth_done) step <= step + 3'd1;
            end
        end
    end

    reg [15:0] tone_count;
    reg        audio_out;
    always @(posedge clk) begin
        if (!rst_n || !audio_active) begin
            tone_count <= 16'd0; audio_out <= 1'b0;
        end else if (tone_count == 16'd0) begin
            tone_count <= hp_m1;
            audio_out  <= ~audio_out;
        end else tone_count <= tone_count - 16'd1;
    end

    assign speaker = audio_out & ~gap & audio_active;

    // Lint suppression
    wire _unused_bits = &{1'b0, dx[2:0], by_d[1:0]};

endmodule
