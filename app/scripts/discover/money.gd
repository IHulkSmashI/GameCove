extends RefCounted
## Currencies: which one a country pays in on Steam, and short price labels.
## Nothing is ever converted: every number shown is a store's own price for
## the user's country (see prices.gd).

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


## "C$ 4.39", "$3.99", "€19,99" style labels, kept simple: symbol + amount.
static func format(amount: Variant, currency: String) -> String:
	if amount == null:
		return ""
	var digits := 0 if currency in NO_DECIMALS else 2
	var num := String.num(float(amount), digits)
	if digits == 2 and num.find(".") == -1:
		num += ".00"
	elif digits == 2 and num.length() - num.find(".") == 2:
		num += "0"
	var sym: String = SYMBOL.get(currency, currency + " ")
	return sym + num
