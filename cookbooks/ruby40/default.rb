# frozen_string_literal: true

# The rbenv cookbook provides the `rbenv` definition; including it here lets
# `COOKBOOK=ruby40 mitamae local test-cookbook.rb` apply this cookbook alone.
include_cookbook "rbenv"

rbenv "4.0.5"

