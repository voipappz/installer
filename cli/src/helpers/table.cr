require "./colors"

module VoIPAppz::Table
  TL = "┌"
  TR = "┐"
  BL = "└"
  BR = "┘"
  H  = "─"
  V  = "│"
  TJ = "┬"
  BJ = "┴"
  LJ = "├"
  RJ = "┤"
  CJ = "┼"

  struct Column
    getter header : String
    getter width : Int32

    def initialize(@header, @width)
    end
  end

  def self.render(columns : Array(Column), rows : Array(Array(String)), title : String? = nil) : String
    output = String::Builder.new

    if title
      output << "\n  #{Colors::BOLD}#{title}#{Colors::RESET}\n"
    end

    # Top border
    output << "  #{TL}"
    columns.each_with_index do |col, i|
      output << H * (col.width + 2)
      output << (i < columns.size - 1 ? TJ : TR)
    end
    output << "\n"

    # Header row
    output << "  #{V}"
    columns.each do |col|
      output << " #{col.header.ljust(col.width)} "
      output << V
    end
    output << "\n"

    # Header separator
    output << "  #{LJ}"
    columns.each_with_index do |col, i|
      output << H * (col.width + 2)
      output << (i < columns.size - 1 ? CJ : RJ)
    end
    output << "\n"

    # Data rows
    rows.each do |row|
      output << "  #{V}"
      row.each_with_index do |cell, i|
        if i < columns.size
          visible_len = cell.gsub(/\e\[[0-9;]*m/, "").size
          padding = columns[i].width - visible_len
          padding = 0 if padding < 0
          output << " #{cell}#{" " * padding} "
        end
        output << V
      end
      output << "\n"
    end

    # Bottom border
    output << "  #{BL}"
    columns.each_with_index do |col, i|
      output << H * (col.width + 2)
      output << (i < columns.size - 1 ? BJ : BR)
    end
    output << "\n"

    output.to_s
  end
end
