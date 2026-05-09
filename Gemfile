source "https://rubygems.org"

# GitHub Pages bundle keeps everything Pages-compatible in one go.
# https://pages.github.com/versions/
gem "github-pages", group: :jekyll_plugins

group :jekyll_plugins do
  gem "jekyll-feed"
  gem "jekyll-seo-tag"
  gem "jekyll-sitemap"
end

# Performance booster on Linux/macOS local dev
gem "wdm", "~> 0.1.1", :install_if => Gem.win_platform?

# Lock http_parser.rb to v0.6.x on JRuby; otherwise no-op.
gem "http_parser.rb", "~> 0.6.0", :platforms => [:jruby]
