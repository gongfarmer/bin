#!/usr/bin/ruby

# Author:  Fraser Hanson
# Date:    2017-07-12
# Purpose: Given a list of files on STDIN, compress each file and delete the
# original.
# Intended to save space by replacing large files with a maximally compressed
# version.
# Finding the large files is not handled, it operates on whatever filepaths are
# given on STDIN.
#
# Compression is performed by xz, which is currently the best choice for
# achieving maximum compression, at the cost of slow compression times vs gzip.
# xz is also a good choice because it can use multiple threads to process the
# same input (this configuration is used by this tool.)
#
# Generate a list of input files with something like this:
#    find /ssd -type f -a -size +1G
require 'time'

class Error < StandardError; end

ONE_GIB_IN_BYTES = (1024**3).freeze
ONE_MIB_IN_BYTES = (1024**2).freeze
ONE_KIB_IN_BYTES = 1024

# Provide method to convert seconds into a readable elapsed time string
class Numeric
  def duration
    secs = to_int
    mins = secs / 60
    hours = mins / 60
    days = hours / 24
    case
    when days > 0 then "#{days} days and #{hours % 24} hours"
    when hours > 0 then "#{hours} hours and #{mins % 60} minutes"
    when mins > 0 then "#{mins} minutes and #{secs % 60} seconds"
    else "#{secs} seconds"
    end
  end
end

# Run the xz compression command
module XZ
  Result = Struct.new(
    :bytes_compressed,
    :bytes_uncompressed,
    :compression_ratio,
    :path_compressed,
    :path_uncompressed
  ) {}

  # Use XZ to compress a file. Return the compressed file and its size.
  # Optionally delete the original.
  # Return a list containing the following:
  # [compressed filename, bytes in original file, bytes in compressed file]
  def self.compress(path)
    raise 'Not a file: ' << path unless File.file? path
    check_size path
    result = do_compression path # raises error on failures such as ENOSPC
    result
  end

  module_function

  def self.do_compression(path)
    cmd = format '/usr/bin/xz -9 --threads=0 --verbose "%s" ', path
    output = `#{cmd} 2>&1`
    read_result output
  end

  # Sample output
  # "/tmp/big-grid.xml: 453.4 KiB / 2,585.8 KiB = 0.175\n"
  def read_result(str)
    arr = str.split
    # ["/tmp/file:", "453.4", "KiB", "/", "2,585.8", "KiB", "=", "0.175"]
    bytes_compressed = (arr[1].delete(',').to_f * ONE_KIB_IN_BYTES).to_i
    bytes_uncompressed = (arr[4].delete(',').to_f * ONE_KIB_IN_BYTES).to_i
    compression_ratio = arr.last.to_f
    path_uncompressed = arr.first.chop # xz command fails if out filename exists
    path_compressed = path_uncompressed + '.xz'
    Result.new bytes_compressed, bytes_uncompressed, compression_ratio, path_compressed, path_uncompressed
  end

  def self.check_size(path)
    # If we're going to handle files this small, then reconsider the xz
    # compression settings before removing this check. This tool is intended to
    # recaim space from large files.
    msg = 'This file is really small, why compress it? ' << path
    raise Error, msg if File.size(path) < ONE_MIB_IN_BYTES
  end
end

def summarize_space(count, total_bytes_uncompressed, total_bytes_compressed)
  puts format('Updated %d files.', count)
  return if count.zero?

  gb = total_bytes_uncompressed / ONE_GIB_IN_BYTES.to_f
  puts format('GiB before: %7.1f', gb)

  gb = total_bytes_compressed / ONE_GIB_IN_BYTES.to_f
  puts format('GiB after:  %7.1f', gb)

  gb =
    (total_bytes_uncompressed - total_bytes_compressed) / ONE_GIB_IN_BYTES.to_f
  puts format('GiB saved:  %7.1f', gb)
end

def main
  count = 0
  total_bytes_uncompressed = 0
  total_bytes_compressed = 0
  t_start = Time.now
  puts format('startup at %s.', t_start.strftime('%F %T'))
  sleep 10
  ARGF.each_line do |path|
    path.chop!
    next unless File.file? path
    if File.size(path) < ONE_MIB_IN_BYTES
      $stderr.puts 'WARNING: discarding small file ' << path
      next
    end

    # Found a viable candidate for compression.
    r = XZ.compress path
    puts format('%0.3f%%  %s', r.compression_ratio, path)
    total_bytes_uncompressed += r.bytes_uncompressed
    total_bytes_compressed += r.bytes_compressed
    count += 1
  end
  t_total = Time.now - t_start
  puts format('Finished in %s.', t_total.duration)
  summarize_space count, total_bytes_uncompressed, total_bytes_compressed
end

begin
  main
rescue Error => e
  $stderr.puts e
  exit 1
end
