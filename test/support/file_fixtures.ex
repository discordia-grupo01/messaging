defmodule Messaging.FileFixtures do
  def jpeg(extra \\ 16), do: <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<0>>, extra)

  def png(extra \\ 16),
    do: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<0>>, extra)

  def webp(extra \\ 16), do: "RIFF" <> <<0, 0, 0, 0>> <> "WEBP" <> :binary.copy(<<0>>, extra)

  def gif(extra \\ 16), do: "GIF89a" <> :binary.copy(<<0>>, extra)

  def pdf(extra \\ 16), do: "%PDF-1.7\n" <> :binary.copy("x", extra)

  def sized(kind, bytes) do
    header = apply(__MODULE__, kind, [0])
    header <> :binary.copy(<<0>>, bytes - byte_size(header))
  end
end
