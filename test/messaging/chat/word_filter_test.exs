defmodule Messaging.Chat.WordFilterTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.WordFilter

  test "no list, nothing to find" do
    assert WordFilter.matches("cualquier cosa", []) == []
  end

  test "ignores case and accents, both in the message and in the list" do
    assert WordFilter.matches("Sos un TÓNTO", ["tonto"]) == ["tonto"]
    assert WordFilter.matches("sos un tonto", ["tónto"]) == ["tónto"]
  end

  test "only whole words: a banned word inside another one doesn't count" do
    assert WordFilter.matches("qué buena película", ["culo"]) == []
    assert WordFilter.matches("tontos", ["tonto"]) == []
  end

  test "punctuation, emojis and line breaks separate words" do
    assert WordFilter.matches("¡¡TONTO!!", ["tonto"]) == ["tonto"]
    assert WordFilter.matches("hola,tonto.", ["tonto"]) == ["tonto"]
    assert WordFilter.matches("ay🙄tonto\nchau", ["tonto"]) == ["tonto"]
  end

  test "a phrase matches the same words in a row, whatever is between them" do
    assert WordFilter.matches("esto NO   sirve!", ["no sirve"]) == ["no sirve"]
    assert WordFilter.matches("no, esto sirve", ["no sirve"]) == []
  end

  test "returns every banned word found, in the list's order" do
    assert WordFilter.matches("feo y tonto", ["tonto", "malo", "feo"]) == ["tonto", "feo"]
  end

  test "a list entry that is only punctuation never matches everything" do
    assert WordFilter.matches("hola", ["!!!"]) == []
  end
end
