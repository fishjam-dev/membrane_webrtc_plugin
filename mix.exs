defmodule Membrane.WebRTC.Plugin.Mixfile do
  use Mix.Project

  @version "0.6.2"
  @github_url "https://github.com/membraneframework/membrane_webrtc_plugin"

  def project do
    [
      app: :membrane_webrtc_plugin,
      version: @version,
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # hex
      description: "Plugin for sending and receiving media with WebRTC",
      package: package(),

      # docs
      name: "Membrane WebRTC plugin",
      source_url: @github_url,
      homepage_url: "https://membraneframework.org",
      docs: docs(),
      releases: [
        otel_getting_started: [
          version: "0.0.1",
          applications: [otel_getting_started: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_opentelemetry, github: "membraneframework/membrane_opentelemetry"},
      {:membrane_core, "~> 0.10.0"},
      {:qex, "~> 0.5.0"},
      {:bunch, "~> 1.3.0"},
      {:ex_sdp, "~> 0.7.0"},
      {:membrane_rtp_plugin, "~> 0.14.0"},
      {:membrane_rtp_format, "~> 0.5.0"},
      {:membrane_ice_plugin, github: "membraneframework/membrane_ice_plugin"},
      {:membrane_funnel_plugin, "~> 0.6.0"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.21.0"},
      {:membrane_rtp_vp8_plugin, "~> 0.6.0"},
      {:membrane_rtp_h264_plugin, "~> 0.13.0"},
      {:membrane_rtp_opus_plugin, "~> 0.6.0"},
      {:ex_libsrtp, "~> 0.4.0"},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:credo, "~> 1.6", only: :dev, runtime: false},

      # Otel
      {:opentelemetry_api, "~> 1.0"},
      {:opentelemetry, "~> 1.0"}
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}",
      formatters: ["html"],
      nest_modules_by_prefix: [Membrane.WebRTC]
    ]
  end
end
