<?php
$name = "PHP"; $ver = 8;
echo "Running $name $ver on BEAM\n";
echo "{$name}->{$ver}\n";
$arr = ["k" => "V"];
echo "val: $arr[k]\n";
echo <<<'EOT'
raw $name \n
EOT;
echo <<<EOT
interp $name and {$ver}
EOT;
$s = "hello";
echo "$s[0]$s[4] $s\n";
echo "esc: \t|\\|\$|\"\n";
echo "unicode: \u{1F600}\n";
