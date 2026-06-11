defmodule PowerModelWeb.PageControllerTest do
  use PowerModelWeb.ConnCase

  @tag :skip
  test "GET / redirects to grid view", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "grid-map"
  end
end
