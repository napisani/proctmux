#!/bin/bash
# Quick viewer test - outputs text continuously
for i in {1..20}; do
  echo "Line $i at $(date +%H:%M:%S)"
  sleep 0.5
done
