#import "MarkdownPreviewSanitizer.h"
#import <string>
#import <set>

static std::set<std::string> const kAllowedTags = {
	"a", "abbr", "b", "bdi", "bdo", "blockquote", "br", "caption", "cite", "code",
	"dd", "del", "details", "dfn", "div", "dl", "dt", "em", "figcaption", "figure",
	"h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "input", "ins", "kbd",
	"li", "mark", "ol", "p", "pre", "q", "rp", "rt", "ruby", "s", "samp", "section",
	"small", "span", "strike", "strong", "sub", "summary", "sup", "table", "tbody",
	"td", "tfoot", "th", "thead", "time", "tr", "tt", "u", "ul", "var", "wbr",
};

static std::set<std::string> const kVoidTags = { "br", "hr", "img", "input", "wbr" };

// Allowed on every tag, as are data-* (cmark-gfm’s data-sourcepos, footnotes)
static std::set<std::string> const kGlobalAttributes = {
	"align", "aria-hidden", "aria-label", "class", "dir", "id", "lang", "title",
};

static bool is_allowed_attribute (std::string const& tag, std::string const& name)
{
	if(kGlobalAttributes.count(name) || name.compare(0, 5, "data-") == 0)
		return true;

	static std::set<std::pair<std::string, std::string>> const allowed = {
		{ "a", "href" }, { "a", "name" },
		{ "img", "src" }, { "img", "alt" }, { "img", "width" }, { "img", "height" },
		{ "input", "type" }, { "input", "checked" }, { "input", "disabled" },
		{ "ol", "start" }, { "ol", "reversed" }, { "ol", "type" },
		{ "td", "colspan" }, { "td", "rowspan" }, { "th", "colspan" }, { "th", "rowspan" },
		{ "details", "open" }, { "pre", "lang" }, { "time", "datetime" },
		{ "blockquote", "cite" }, { "q", "cite" }, { "del", "cite" }, { "ins", "cite" },
	};
	return allowed.count({ tag, name });
}

static std::string lowercase (std::string str)
{
	for(char& ch : str)
		ch = tolower((unsigned char)ch);
	return str;
}

// Decodes the entities that could hide a scheme (“javascript&#58;…”) and
// drops whitespace and control characters, as browsers do in URLs
static std::string normalized_url (std::string const& value)
{
	std::string res;
	for(size_t i = 0; i < value.size(); )
	{
		if(value[i] == '&')
		{
			size_t semicolon = value.find(';', i);
			if(semicolon != std::string::npos && semicolon - i < 12)
			{
				std::string entity = lowercase(value.substr(i + 1, semicolon - i - 1));
				long code = -1;
				if(entity.size() > 1 && entity[0] == '#')
					code = entity[1] == 'x' ? strtol(entity.c_str() + 2, nullptr, 16) : strtol(entity.c_str() + 1, nullptr, 10);
				else if(entity == "colon")
					code = ':';
				else if(entity == "tab" || entity == "newline")
					code = ' ';

				if(code >= 0)
				{
					if(code > ' ' && code < 0x7f)
						res += (char)code;
					i = semicolon + 1;
					continue;
				}
			}
		}
		if((unsigned char)value[i] > ' ' && value[i] != 0x7f)
			res += value[i];
		++i;
	}
	return lowercase(res);
}

static bool is_safe_url (std::string const& value, bool image)
{
	std::string const url = normalized_url(value);
	size_t const colon = url.find(':');
	if(colon == std::string::npos || colon > url.find_first_of("/?#"))
		return true; // relative

	std::string const scheme = url.substr(0, colon);
	if(scheme == "http" || scheme == "https" || scheme == "mailto")
		return true;
	if(image && scheme == "data")
	{
		for(char const* type : { "data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp" })
		{
			if(url.compare(0, strlen(type), type) == 0)
				return true;
		}
	}
	return false;
}

static bool is_name_char (char ch)
{
	return isalnum((unsigned char)ch) || ch == '-';
}

static void append_escaped (std::string& dst, std::string const& value)
{
	for(char ch : value)
	{
		switch(ch)
		{
			case '"': dst += "&quot;"; break;
			case '<': dst += "&lt;";   break;
			case '>': dst += "&gt;";   break;
			default:  dst += ch;       break;
		}
	}
}

// Parses the tag starting at `src[from]` (“<”). Returns the index after it,
// or npos if it isn’t a tag; `dst` gets the tag if it’s allowed.
static size_t sanitize_tag (std::string const& src, size_t from, std::string& dst)
{
	size_t i = from + 1;
	bool const endTag = i < src.size() && src[i] == '/';
	if(endTag)
		++i;
	if(i == src.size() || !isalpha((unsigned char)src[i]))
		return std::string::npos;

	size_t const nameStart = i;
	while(i < src.size() && is_name_char(src[i]))
		++i;
	std::string const tag = lowercase(src.substr(nameStart, i - nameStart));

	std::string attributes;
	bool hasType = false, isCheckbox = false, hasDisabled = false, selfClosing = false;
	while(true)
	{
		while(i < src.size() && isspace((unsigned char)src[i]))
			++i;
		if(i == src.size())
			return std::string::npos;
		if(src[i] == '>')
			break;
		if(src[i] == '/')
		{
			selfClosing = i + 1 < src.size() && src[i+1] == '>';
			++i;
			continue;
		}

		size_t const attrStart = i;
		while(i < src.size() && !isspace((unsigned char)src[i]) && src[i] != '/' && src[i] != '>' && src[i] != '=')
			++i;
		std::string const name = lowercase(src.substr(attrStart, i - attrStart));

		while(i < src.size() && isspace((unsigned char)src[i]))
			++i;

		bool hasValue = false;
		std::string value;
		if(i < src.size() && src[i] == '=')
		{
			hasValue = true;
			++i;
			while(i < src.size() && isspace((unsigned char)src[i]))
				++i;
			if(i < src.size() && (src[i] == '"' || src[i] == '\''))
			{
				size_t const close = src.find(src[i], i + 1);
				if(close == std::string::npos)
					return std::string::npos;
				value = src.substr(i + 1, close - i - 1);
				i = close + 1;
			}
			else
			{
				size_t const valueStart = i;
				while(i < src.size() && !isspace((unsigned char)src[i]) && src[i] != '>')
					++i;
				value = src.substr(valueStart, i - valueStart);
			}
		}

		if(endTag || name.empty() || !is_allowed_attribute(tag, name))
			continue;
		if((name == "href" || name == "src" || name == "cite") && !is_safe_url(value, tag == "img"))
			continue;

		if(name == "type")
		{
			hasType    = true;
			isCheckbox = lowercase(value) == "checkbox";
		}
		hasDisabled = hasDisabled || name == "disabled";

		attributes += " " + name;
		if(hasValue)
		{
			attributes += "=\"";
			append_escaped(attributes, value);
			attributes += "\"";
		}
	}
	++i; // “>”

	if(!kAllowedTags.count(tag))
		return i;
	if(tag == "input" && (!hasType || !isCheckbox))
		return i;

	if(endTag)
	{
		if(!kVoidTags.count(tag))
			dst += "</" + tag + ">";
		return i;
	}

	if(tag == "input" && !hasDisabled)
		attributes += " disabled=\"\"";
	dst += "<" + tag + attributes + (selfClosing ? " />" : ">");
	return i;
}

NSString* MarkdownPreviewSanitizedHTML (NSString* html)
{
	std::string const src = html.UTF8String ?: "";
	std::string dst;
	dst.reserve(src.size());

	for(size_t i = 0; i < src.size(); )
	{
		size_t const lt = src.find('<', i);
		dst.append(src, i, (lt == std::string::npos ? src.size() : lt) - i);
		if(lt == std::string::npos)
			break;

		if(src.compare(lt, 4, "<!--") == 0)
		{
			size_t const end = src.find("-->", lt + 4);
			i = end == std::string::npos ? src.size() : end + 3;
			continue;
		}

		size_t const next = sanitize_tag(src, lt, dst);
		if(next == std::string::npos)
		{
			dst += "&lt;";
			i = lt + 1;
		}
		else
		{
			i = next;
		}
	}
	return [NSString stringWithUTF8String:dst.c_str()];
}
