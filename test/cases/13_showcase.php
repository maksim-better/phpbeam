<?php
// 综合验收：lexer + parser + 求值 + 类 + 异常 + 高阶函数 + 插值
namespace Showcase;

use Showcase\Currency as Money;

const APP = "phpbeam";

class Currency {
    public const SYMBOL = "€";
    private static array $rates = ["USD" => 0.92, "GBP" => 1.17, "JPY" => 0.0061];

    public static function rate(string $code): float {
        return self::$rates[$code] ?? 1.0;
    }
}

class Cart implements \Countable {
    private array $items = [];

    public function add(string $name, float $price, int $qty = 1): static {
        $this->items[] = ["name" => $name, "total" => $price * $qty];
        return $this;
    }

    public function count(): int { return count($this->items); }

    public function total(string $currency = "EUR"): float {
        $sum = array_sum(array_map(fn($i) => $i["total"], $this->items));
        return round($sum * Money::rate($currency), 2);
    }
}

$cart = (new Cart())
    ->add("coffee", 3.5, 2)
    ->add("book", 12.99)
    ->add("tea", 2.25, 3);

printf("%s cart: %d items, %s%.2f\n", APP, count($cart), Money::SYMBOL, $cart->total());
printf("in USD: %.2f\n", $cart->total("USD"));

$words = ["beam", "php", "elixir"];
usort($words, fn($a, $b) => strlen($b) <=> strlen($a));
echo implode(" > ", $words), "\n";

try {
    $r = intdiv(1, 0);
} catch (ArithmeticError $e) {
    echo "caught: ", $e->getMessage(), "\n";
} finally {
    echo "cart had ", $cart->count(), " items\n";
}

$squares = array_map(fn($n) => $n ** 2, range(1, 5));
echo implode("+", $squares), " = ", array_sum($squares), "\n";
echo "interpolation: {$cart->count()} items for ~" . Money::SYMBOL . $cart->total(), "\n";
