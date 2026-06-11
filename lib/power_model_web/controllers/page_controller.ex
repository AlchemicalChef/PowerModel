defmodule PowerModelWeb.PageController do
  use PowerModelWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
