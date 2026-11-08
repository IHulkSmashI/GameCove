extends RefCounted
## Currencies: which one a country pays in on Steam, converting with the ECB
## reference rates the nightly job publishes (EUR base, "Source: ECB
## statistics"), and short price labels. Converted prices are estimates and
## every Deal carrying one says so ("converted": true).

## Steam store currency per country (ISO 3166-1 alpha-2). Countries not listed
## are treated as paying in USD, as Steam does for many of them; the Steam
## price label (price_text) always comes from Steam itself either way.
const STEAM_CURRENCY := {
	"US": "USD", "CA": "CAD", "GB": "GBP", "AU": "AUD", "NZ": "NZD", "JP": "JPY", "KR": "KRW",
	"CN": "CNY", "HK": "HKD", "TW": "TWD", "SG": "SGD", "MY": "MYR", "TH": "THB", "PH": "PHP",
	"ID": "IDR", "VN": "VND", "IN": "INR", "BR": "BRL", "MX": "MXN", "CL": "CLP", "CO": "COP",
	"PE": "PEN", "UY": "UYU", "CR": "CRC", "ZA": "ZAR", "IL": "ILS", "SA": "SAR", "AE": "AED",
	"QA": "QAR", "KW": "KWD", "KZ": "KZT", "UA": "UAH", "NO": "NOK", "CH": "CHF", "PL": "PLN",
	"SE": "EUR", "DK": "EUR", "CZ": "EUR", "HU": "EUR", "RO": "EUR", "BG": "EUR",
	"DE": "EUR", "FR": "EUR", "IT": "EUR", "ES": "EUR", "NL": "EUR", "BE": "EUR", "AT": "EUR",
	"FI": "EUR", "IE": "EUR", "PT": "EUR", "GR": "EUR", "SK": "EUR", "SI": "EUR", "LT": "EUR",
	"LV": "EUR", "EE": "EUR", "LU": "EUR", "MT": "EUR", "CY": "EUR", "HR": "EUR",
}
const SYMBOL := {"USD": "$", "CAD": "C$", "AUD": "A$", "NZD": "NZ$", "GBP": "£", "EUR": "€",
	"JPY": "¥", "CNY": "¥", "KRW": "₩", "INR": "₹", "BRL": "R$", "MXN": "Mex$", "CHF": "CHF ",
	"PLN": "zł ", "NOK": "kr ", "SEK": "kr ", "DKK": "kr "}
const NO_DECIMALS := ["JPY", "KRW", "IDR", "VND", "CLP", "COP", "KZT", "CRC", "UYU"]


static func currency_for_country(country: String) -> String:
	return STEAM_CURRENCY.get(country.to_upper(), "USD")


## Country from a locale like "en_CA" or "fr_CA.UTF-8"; "US" when it has none.
static func country_from_locale(locale: String) -> String:
	var parts := locale.split(".")[0].split("_")
	if parts.size() >= 2 and parts[1].length() == 2:
		return parts[1].to_upper()
	return "US"


## `amount` in `from` converted to `to` with ECB rates ({"base": "EUR",
## "rates": {"USD": 1.1, ...}}), or null when a rate is missing.
static func convert(amount: Variant, from: String, to: String, fx: Dictionary) -> Variant:
	if amount == null:
		return null
	if from == to:
		return float(amount)
	var rates: Dictionary = fx.get("rates", {}) if fx.get("rates") is Dictionary else {}
	var base: String = fx.get("base", "EUR")
	var r_from: float = 1.0 if from == base else float(rates.get(from, 0.0))
	var r_to: float = 1.0 if to == base else float(rates.get(to, 0.0))
	if r_from <= 0.0 or r_to <= 0.0:
		return null
	return snappedf(float(amount) / r_from * r_to, 0.01)


## "C$ 4.39", "$3.99", "€19,99" style labels, kept simple: symbol + amount.
static func format(amount: Variant, currency: String, approx := false) -> String:
	if amount == null:
		return ""
	var digits := 0 if currency in NO_DECIMALS else 2
	var num := String.num(float(amount), digits)
	if digits == 2 and num.find(".") == -1:
		num += ".00"
	elif digits == 2 and num.length() - num.find(".") == 2:
		num += "0"
	var sym: String = SYMBOL.get(currency, currency + " ")
	return ("~" if approx else "") + sym + num
