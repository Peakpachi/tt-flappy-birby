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
        .left(ui_in[2]), 
        .x(x), .y(y), .active(active), .frame(frame),
        .rgb(rgb),
        .speaker(speaker) 
    );

    // TinyVGA PMOD pin order
    assign uo_out = {hsync, rgb[0], rgb[2], rgb[4], vsync, rgb[1], rgb[3], rgb[5]};
    
    // Route speaker to pin 7
    assign uio_out = {speaker, 7'b0000000};
    assign uio_oe  = {1'b1,    7'b0000000}; 

    // Unused wires
    wire _unused = &{ena, uio_in, ui_in[7:3], ui_in[1:0], 1'b0};
    
endmodule`default_nettype none

`default_nettype none

module game_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       left,      // ui_in[2] from top module (Button 3)
    input  wire [9:0] x,         
    input  wire [9:0] y,         
    input  wire       active,    
    input  wire       frame,     
    output wire [5:0] rgb,
    output wire       speaker    
);

    localparam [9:0] BIRD_X     = 10'd160; 
    // 8x8 grid scaled 3x3 = 24x24 pixels wide/tall
    localparam [9:0] BIRD_W     = 10'd24;  
    localparam [9:0] BIRD_H     = 10'd24;  
    localparam [9:0] PIPE_W     = 10'd48;  
    localparam [9:0] GAP_H      = 10'd130; 
    
    localparam signed [4:0] JUMP_VEL = -5'sd8;
    localparam signed [4:0] GRAVITY  = 5'sd1;

    // 1. Button Handling
    wire flap_raw = left;
    wire flap_clean;
    reg  flap_last;
    
    // Button: synchronised, then sampled once per frame (16.7 ms) instead of the 500000-clock
    // (19.9 ms) ip_debounce. A press is seen 0..16.7 ms after it starts (original: 19.9 ms).
    reg        db_s1, db_s2, db_clean;
    always @(posedge clk) begin
        if (!rst_n) begin
            db_s1 <= 1'b0; db_s2 <= 1'b0; db_clean <= 1'b0;
        end else begin
            db_s1 <= flap_raw;
            db_s2 <= db_s1;
            if (frame) db_clean <= db_s2;
        end
    end
    assign flap_clean = db_clean;
    always @(posedge clk) flap_last <= flap_clean;
    
    wire jump_pulse = flap_clean & ~flap_last; 
    reg jump_pending;
    always @(posedge clk) begin
        if (!rst_n) jump_pending <= 1'b0;
        else if (jump_pulse) jump_pending <= 1'b1;
        else if (frame) jump_pending <= 1'b0;
    end

    // 2. High-Speed Random Number Generator 
    reg [7:0] rand_y;
    always @(posedge clk) begin
        if (rand_y >= 8'd180) rand_y <= 8'd0;
        else rand_y <= rand_y + 1'b1;
    end

    // 3. Game State Registers
    reg [8:0] bird_y_r;            // 0..456
    wire [9:0] bird_y = {1'b0, bird_y_r};
    reg signed [4:0] velocity;   // range -8..15
    
    reg [9:0] pipe1_x;
    reg [7:0] pipe1_gap_y;
    reg [9:0] pipe2_x;
    reg [7:0] pipe2_gap_y;
    reg       pipe1_passed, pipe2_passed;
    
    reg [3:0] score_tens, score_ones;
    reg [3:0] h_score_tens, h_score_ones; 
    reg       game_over;

    wire signed [10:0] bird_y_11 = {1'b0, bird_y};
    wire signed [10:0] vel_11    = {{6{velocity[4]}}, velocity};
    wire signed [10:0] next_y    = bird_y_11 + vel_11;

    wire [9:0] pipe_speed = 10'd3 + {6'd0, score_tens};
    
    // pipe_x is at most 960, so pipe_x + 48 never overflows 10 bits: the compares below use constants.
    wire [10:0] p1_next = {1'b0, pipe1_x} - {1'b0, pipe_speed};   // bit 10 = 1 means pipe1_x < pipe_speed
    wire [10:0] p2_next = {1'b0, pipe2_x} - {1'b0, pipe_speed};
    wire p1_pass = !pipe1_passed && (pipe1_x < BIRD_X - PIPE_W);  // pipe1_x + 48 < 160
    wire p2_pass = !pipe2_passed && (pipe2_x < BIRD_X - PIPE_W);
    wire score_gt_high = (score_tens > h_score_tens) || ((score_tens == h_score_tens) && (score_ones > h_score_ones));

    wire game_restart = game_over && (bird_y >= 10'd480 - BIRD_H) && jump_pending;

    // 4. Main Game Loop
    always @(posedge clk) begin
        if (!rst_n) begin
            bird_y_r     <= 9'd240;
            velocity     <= 5'sd0;
            pipe1_x      <= 10'd640;
            pipe2_x      <= 10'd960;
            pipe1_gap_y  <= 8'd160;
            pipe2_gap_y  <= 8'd220;
            pipe1_passed <= 1'b0;
            pipe2_passed <= 1'b0;
            score_tens   <= 4'd0;
            score_ones   <= 4'd0;
            h_score_tens <= 4'd0;
            h_score_ones <= 4'd0;
            game_over    <= 1'b0;
        end else if (frame) begin
            
            if (crash1 || crash2 || (bird_y >= 10'd480 - BIRD_H)) game_over <= 1'b1;

            if (score_gt_high) begin
                h_score_tens <= score_tens;
                h_score_ones <= score_ones;
            end

            if (game_over) begin
                if (velocity < 5'sd15) velocity <= velocity + GRAVITY;
                
                if (next_y > 10'd480 - BIRD_H) bird_y_r <= 9'd456;
                else bird_y_r <= next_y[8:0];

                if (game_restart) begin
                    bird_y_r     <= 9'd240;
                    velocity     <= 5'sd0;
                    pipe1_x      <= 10'd640;
                    pipe2_x      <= 10'd960;
                    pipe1_passed <= 1'b0;
                    pipe2_passed <= 1'b0;
                    score_tens   <= 4'd0;
                    score_ones   <= 4'd0;
                    game_over    <= 1'b0;
                end
            end else begin
                if (jump_pending) velocity <= JUMP_VEL;
                else if (velocity < 5'sd15) velocity <= velocity + GRAVITY;
                
                if (next_y < 0) bird_y_r <= 9'd0;
                else if (next_y > 10'd480 - BIRD_H) bird_y_r <= 9'd456;
                else bird_y_r <= next_y[8:0];
                
                if (p1_next[10]) begin
                    pipe1_x <= 10'd640;
                    pipe1_gap_y <= 8'd50 + rand_y;   // rand_y <= 180, so <= 230
                    pipe1_passed <= 1'b0;
                end else pipe1_x <= p1_next[9:0];

                if (p2_next[10]) begin
                    pipe2_x <= 10'd640;
                    pipe2_gap_y <= 8'd50 + rand_y;
                    pipe2_passed <= 1'b0;
                end else pipe2_x <= p2_next[9:0];

                if (p1_pass || p2_pass) begin
                    
                    if (score_ones == 4'd9) begin
                        score_ones <= 4'd0;
                        if (score_tens != 4'd9) score_tens <= score_tens + 4'd1;
                    end else score_ones <= score_ones + 4'd1;
                    
                    if (p1_pass) pipe1_passed <= 1'b1;
                    if (p2_pass) pipe2_passed <= 1'b1;
                end
            end
        end
    end

    // 5. Collision Detection
    wire [9:0] gap1_10 = {2'b00, pipe1_gap_y};
    wire [9:0] gap2_10 = {2'b00, pipe2_gap_y};
    wire [9:0] bot_pipe1_y = gap1_10 + GAP_H;
        wire [9:0] bot_pipe2_y = gap2_10 + GAP_H;
    
    wire crash1 = (pipe1_x < BIRD_X + BIRD_W) && (pipe1_x > BIRD_X - PIPE_W) &&
                  ((bird_y < gap1_10) || (bird_y + BIRD_H > bot_pipe1_y));
                  
    wire crash2 = (pipe2_x < BIRD_X + BIRD_W) && (pipe2_x > BIRD_X - PIPE_W) &&
                  ((bird_y < gap2_10) || (bird_y + BIRD_H > bot_pipe2_y));

    // 6. Graphics Hitboxes & 8x8 Scaled 3x3 New Bird Sprite ROM (No Flip)
    wire [9:0] bx_full = x - BIRD_X;
    wire [10:0] by_d = {1'b0, y} - {1'b0, bird_y};   // y >= bird_y && y < bird_y + 24
    wire [9:0] by_full = by_d[9:0];
    
    wire in_bird_box = (x >= BIRD_X) && (x < BIRD_X + BIRD_W) && (by_d < {1'b0, BIRD_H});
    
    wire [4:0] bx_div = bx_full[4:0] / 5'd3;
    wire [4:0] by_div = by_full[4:0] / 5'd3;
    
    wire [2:0] bx = bx_div[2:0];
    wire [2:0] by = by_div[2:0];

    reg [2:0] p_color;
    always @(*) begin
        p_color = 3'd0; 
        if (in_bird_box) begin
            case (by)
                3'd0: if (bx == 3'd4 || bx == 3'd5)             p_color = 3'd3;
                3'd1: if (bx >= 3'd3 && bx <= 3'd6)             p_color = 3'd3;
                3'd2: begin
                    if (bx == 3'd3 || bx == 3'd4 || bx == 3'd6)  p_color = 3'd3;
                    else if (bx == 3'd5)                        p_color = 3'd4;
                end
                3'd3: begin
                    if (bx >= 3'd0 && bx <= 3'd5)             p_color = 3'd3;
                    else if (bx == 3'd6 || bx == 3'd7)          p_color = 3'd7;
                end
                3'd4: if (bx >= 3'd0 && bx <= 3'd5)             p_color = 3'd3;
                3'd5: if (bx >= 3'd1 && bx <= 3'd5)             p_color = 3'd3;
                3'd6: if (bx >= 3'd2 && bx <= 3'd4)             p_color = 3'd3;
                default: p_color = 3'd0;
            endcase
        end
    end

    wire bird_hit = (p_color != 3'd0);

    wire [10:0] dp1 = {1'b0, x} - {1'b0, pipe1_x};   // x >= pipe1_x && x < pipe1_x + 48
    wire [10:0] dp2 = {1'b0, x} - {1'b0, pipe2_x};
    wire in_p1x = (dp1 < 11'd48);
    wire in_p2x = (dp2 < 11'd48);
    wire t_p1_hit = in_p1x && (y < gap1_10);
    wire b_p1_hit = in_p1x && (y >= bot_pipe1_y) && (y < 10'd480);
    wire t_p2_hit = in_p2x && (y < gap2_10);
    wire b_p2_hit = in_p2x && (y >= bot_pipe2_y) && (y < 10'd480);
    wire pipe_hit = t_p1_hit | b_p1_hit | t_p2_hit | b_p2_hit;

    // 7. SCORE Rendering (Digits 0-9)
    wire in_tens = (x >= 10'd292) && (x < 10'd316) && (y >= 10'd32) && (y < 10'd72);
    wire in_ones = (x >= 10'd324) && (x < 10'd348) && (y >= 10'd32) && (y < 10'd72);
    wire [9:0] y_rel = y - 10'd32;

    wire in_h_tens = (x >= 10'd560) && (x < 10'd584) && (y >= 10'd32) && (y < 10'd72);
    wire in_h_ones = (x >= 10'd592) && (x < 10'd616) && (y >= 10'd32) && (y < 10'd72);
    
    wire [3:0] dig = in_tens ? score_tens : in_ones ? score_ones : in_h_tens ? h_score_tens : h_score_ones;
    // low 5 bits of the digit start: 292 and 324 -> 4, 560 and 592 -> 16 (only dx[4:3] is used)
    wire [4:0] dx    = x[4:0] - ((in_tens || in_ones) ? 5'd4 : 5'd16);
    // row then column select (same bit as font[14 - 3*row - col])
    reg [2:0] drow;
    always @(*) begin
        case (y_rel[5:3])
            3'd0: drow = dfont[14:12]; 3'd1: drow = dfont[11:9]; 3'd2: drow = dfont[8:6];
            3'd3: drow = dfont[5:3];   3'd4: drow = dfont[2:0];  default: drow = 3'b000;
        endcase
    end
    reg [14:0] dfont;
    always @(*) begin
        case (dig)
            4'd0: dfont = 15'b111_101_101_101_111; 4'd1: dfont = 15'b010_110_010_010_111;
            4'd2: dfont = 15'b111_001_111_100_111; 4'd3: dfont = 15'b111_001_111_001_111;
            4'd4: dfont = 15'b101_101_111_001_001; 4'd5: dfont = 15'b111_100_111_001_111;
            4'd6: dfont = 15'b111_100_111_101_111; 4'd7: dfont = 15'b111_001_001_001_001;
            4'd8: dfont = 15'b111_101_111_101_111; 4'd9: dfont = 15'b111_101_111_001_111;
            default: dfont = 15'b0;
        endcase
    end
    wire lit = (dx[4:3] == 2'd0) ? drow[2] : (dx[4:3] == 2'd1) ? drow[1] : (dx[4:3] == 2'd2) ? drow[0] : 1'b0;
    wire score_hit   = lit && (((score_tens != 4'd0) && in_tens) || in_ones);
    wire h_score_hit = lit && (((h_score_tens != 4'd0) && in_h_tens) || in_h_ones);

    // 8. "YOU LOST" Text Rendering (Restored Original Font Table)
    wire in_yl = (x >= 10'd192) && (x < 10'd448) && (y >= 10'd220) && (y < 10'd260);
    wire [9:0] x_rel_yl = x - 10'd192;
    wire [9:0] y_rel_yl = y - 10'd220;
    wire [2:0] char_idx = x_rel_yl[7:5];    
    wire [4:0] char_x   = x_rel_yl[4:0];    
    wire in_char = (char_x < 5'd24);            
    wire [2:0] char_y_grid = y_rel_yl[5:3]; 
    wire [1:0] char_x_grid = char_x[4:3];   

    
    reg [14:0] yl_font;
    always @(*) begin
        case(char_idx)
            3'd0: yl_font = 15'b101_101_111_010_010; // Y
            3'd1: yl_font = 15'b111_101_101_101_111; // O
            3'd2: yl_font = 15'b101_101_101_101_111; // U
            3'd3: yl_font = 15'b000_000_000_000_000; // Space
            3'd4: yl_font = 15'b100_100_100_100_111; // L
            3'd5: yl_font = 15'b111_101_101_101_111; // O
            3'd6: yl_font = 15'b111_100_111_001_111; // S
            3'd7: yl_font = 15'b111_010_010_010_010; // T
            default: yl_font = 15'b0;
        endcase
    end
    reg [2:0] yrow;
    always @(*) begin
        case (char_y_grid)
            3'd0: yrow = yl_font[14:12]; 3'd1: yrow = yl_font[11:9]; 3'd2: yrow = yl_font[8:6];
            3'd3: yrow = yl_font[5:3];   3'd4: yrow = yl_font[2:0];  default: yrow = 3'b000;
        endcase
    end
    wire yl_lit = (char_x_grid == 2'd0) ? yrow[2] : (char_x_grid == 2'd1) ? yrow[1] : (char_x_grid == 2'd2) ? yrow[0] : 1'b0;
    wire draw_yl = game_over && in_yl && in_char && yl_lit;

    reg [5:0] bird_rgb;
    always @(*) begin
        case (p_color)
            3'd3: bird_rgb = 6'b11_10_00; // Yellow / Gold
            3'd4: bird_rgb = 6'b01_01_01; // Black
            3'd7: bird_rgb = 6'b11_00_00; // Red
            default: bird_rgb = 6'b00_00_00;
        endcase
    end

    // 9. Colour Palette Pipeline
    assign rgb = !active     ? 6'b00_00_00 :
                 draw_yl     ? 6'b11_11_11 : 
                 score_hit   ? 6'b11_11_11 : 
                 h_score_hit ? 6'b11_11_00 : 
                 bird_hit    ? bird_rgb    : 
                 pipe_hit    ? 6'b00_11_00 : 
                 game_over   ? 6'b01_00_00 : 
                               6'b00_10_11 ; 

    // 10. AUDIO SEQUENCER ENGINE
    
    localparam REST = 4'd0, D4 = 4'd1, Ds4 = 4'd2, E4 = 4'd3, F4 = 4'd4,
               C5 = 4'd5, E5 = 4'd6, G5 = 4'd7, C6 = 4'd8;


    reg        audio_active;
    reg [3:0]  index;   // 0..10
    // Each sound ends at index 0, 2, 6 or 10, so end_index is not needed
    wire last_index = (index == 4'd0) || (index == 4'd2) || (index == 4'd6) || (index == 4'd10);
    reg [3:0]  pitch;
    reg [3:0]  length;

    reg game_over_last;
    reg tens_inc;   // 1 clock after score_tens counts up (same as score_tens != its last value)
    reg h_score_beaten;

    always @(posedge clk) begin
        if (!rst_n) begin
            game_over_last <= 1'b0;
            tens_inc <= 1'b0;
        end else begin
            game_over_last <= game_over;
            tens_inc <= frame && !game_over && (p1_pass || p2_pass) && (score_ones == 4'd9) && (score_tens != 4'd9);
        end
    end

    wire crash_pulse    = game_over & ~game_over_last;
    wire score_10_pulse = tens_inc && !game_over;
    wire is_new_high    = score_gt_high && (score_tens != 4'd0 || score_ones != 4'd0);
    wire high_score_pulse = is_new_high && !h_score_beaten && !game_over;

    always @(posedge clk) begin
        if (!rst_n || game_restart) h_score_beaten <= 1'b0;
        else if (high_score_pulse)  h_score_beaten <= 1'b1;
    end

    always @(*) begin
        case (index)
            4'd0: begin pitch = E5; length = 4'd1; end
            4'd1: begin pitch = C5; length = 4'd2; end
            4'd2: begin pitch = G5; length = 4'd4; end
            4'd3: begin pitch = C5; length = 4'd2; end
            4'd4: begin pitch = E5; length = 4'd2; end
            4'd5: begin pitch = G5; length = 4'd2; end
            4'd6: begin pitch = C6; length = 4'd6; end
            4'd7: begin pitch = F4;  length = 4'd4; end
            4'd8: begin pitch = E4;  length = 4'd4; end
            4'd9: begin pitch = Ds4; length = 4'd4; end
            4'd10: begin pitch = D4;  length = 4'd8; end
            default: begin pitch = REST; length = 4'd1; end
        endcase
    end

    // half_period - 1 (exact original periods, the subtraction is done here as constants)
    reg [15:0] hp_m1;
    always @(*) begin
        case (pitch)
            D4:  hp_m1 = 16'd42661;
            Ds4: hp_m1 = 16'd40191;
            E4:  hp_m1 = 16'd37992;
            F4:  hp_m1 = 16'd35815;
            C5:  hp_m1 = 16'd23899;
            E5:  hp_m1 = 16'd18967;
            G5:  hp_m1 = 16'd15942;
            C6:  hp_m1 = 16'd11949;
            default: hp_m1 = 16'hFFFF;
        endcase
    end

    reg [1:0] tick;   // counts frames: 3 frames = 1,260,000 clocks (original 1,250,000)
    reg [2:0]  step;   // length is at most 8
    wire sixteenth_done = frame && (tick == 2'd2);
    wire note_done      = sixteenth_done && ({1'b0, step} == length - 4'd1);

    always @(posedge clk) begin
        if (!rst_n) begin
            tick         <= 2'd0;
            step         <= 3'd0;
            index <= 4'd0;
            audio_active <= 1'b0;
        end else begin
            if (crash_pulse) begin
                index <= 4'd7; audio_active <= 1'b1; tick <= 2'd0; step <= 3'd0;
            end else if (high_score_pulse) begin
                index <= 4'd3;  audio_active <= 1'b1; tick <= 2'd0; step <= 3'd0;
            end else if (score_10_pulse) begin
                index <= 4'd1;  audio_active <= 1'b1; tick <= 2'd0; step <= 3'd0;
            end else if (jump_pulse && !game_over) begin
                index <= 4'd0;  audio_active <= 1'b1; tick <= 2'd0; step <= 3'd0;
            end else if (audio_active) begin
                if (frame) tick <= sixteenth_done ? 2'd0 : tick + 2'd1;
                if (note_done) begin
                    step <= 3'd0;
                    if (last_index) audio_active <= 1'b0;
                    else index <= index + 4'd1;
                end else if (sixteenth_done) begin
                    step <= step + 3'd1;
                end
            end
        end
    end

    wire gap = ({1'b0, step} == length - 4'd1) && (tick == 2'd2)   /* last third of the 16th note (original: last quarter) */;

    // Down counter: same half periods as the original. Only the first half wave after a note
    // change can differ (it ends the half wave that was started, at most 1.7 ms).
    reg [15:0] tone_count;
    reg        audio_out;
    always @(posedge clk) begin
        if (!rst_n || pitch == REST || !audio_active) begin
            tone_count <= 16'd0; audio_out <= 1'b0;
        end else if (tone_count == 16'd0) begin
            tone_count <= hp_m1; audio_out <= ~audio_out;
        end else begin
            tone_count <= tone_count - 16'd1;
        end
    end

    assign speaker = audio_out & ~gap & audio_active;

    // 11. Verilator Lint Fix 
    wire _unused_bits = &{
        1'b0,
        dx[2:0], y_rel[9:6], y_rel[2:0], bx_div[4:3], by_div[4:3],
        x_rel_yl[9:8], y_rel_yl[9:6], y_rel_yl[2:0]
    };

endmodule
