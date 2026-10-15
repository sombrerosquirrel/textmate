#import "OakMarkdown.h"

NSAttributedStringKey const OakMarkdownCodeBlockAttributeName = @"OakMarkdownCodeBlock";
NSAttributedStringKey const OakMarkdownSourceLineAttributeName = @"OakMarkdownSourceLine";
NSAttributedStringKey const OakMarkdownAnchorAttributeName = @"OakMarkdownAnchor";

static CGFloat const kListIndent  = 18;
static CGFloat const kQuoteIndent = 12;

// A system color made translucent with colorWithAlphaComponent: isn’t drawn
// as a text block background, so this is explicit. Created once: creating a
// named dynamic color on several threads at the same time corrupts memory.
static NSColor* CodeBackgroundColor ()
{
	static NSColor* const color = [NSColor colorWithName:@"OakMarkdownCodeBackground" dynamicProvider:^NSColor*(NSAppearance* appearance){
		BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] isEqualToString:NSAppearanceNameDarkAqua];
		return dark ? [NSColor colorWithWhite:1 alpha:0.08] : [NSColor colorWithWhite:0 alpha:0.05];
	}];
	return color;
}

@implementation OakMarkdownStyle
+ (instancetype)defaultStyle
{
	OakMarkdownStyle* style = [[self alloc] init];
	style.font                = [NSFont systemFontOfSize:NSFont.systemFontSize];
	style.codeFont            = [NSFont monospacedSystemFontOfSize:NSFont.systemFontSize - 1 weight:NSFontWeightRegular];
	style.textColor           = NSColor.labelColor;
	style.secondaryTextColor  = NSColor.secondaryLabelColor;
	style.codeBackgroundColor = CodeBackgroundColor();
	style.borderColor         = NSColor.separatorColor;
	return style;
}
@end

@interface OakMarkdownCodeBlock ()
@property (nonatomic, readwrite) NSString* code;
@property (nonatomic, readwrite) NSString* language;
@end

@implementation OakMarkdownCodeBlock
@end

namespace
{
	// Unlike NSFontManager, font descriptors can be used off the main thread
	NSFont* FontWithTrait (NSFont* font, NSFontDescriptorSymbolicTraits trait)
	{
		NSFontDescriptor* descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:font.fontDescriptor.symbolicTraits | trait];
		return [NSFont fontWithDescriptor:descriptor size:font.pointSize] ?: font;
	}

	// The intent chain of a run, innermost first, with the facts we need
	struct block_info_t
	{
		block_info_t (NSPresentationIntent* intent)
		{
			for(NSPresentationIntent* it = intent; it; it = it.parentIntent)
			{
				switch(it.intentKind)
				{
					case NSPresentationIntentKindHeader:         headerLevel = it.headerLevel;                 break;
					case NSPresentationIntentKindCodeBlock:      codeBlock = it;                               break;
					case NSPresentationIntentKindBlockQuote:     ++quoteDepth;                                 break;
					case NSPresentationIntentKindOrderedList:
					case NSPresentationIntentKindUnorderedList:  ++listDepth; if(!list) list = it;             break;
					case NSPresentationIntentKindListItem:       if(!listItem) listItem = it;                  break;
					case NSPresentationIntentKindTable:          table = it;                                   break;
					case NSPresentationIntentKindTableHeaderRow: tableRow = it; headerRow = true;              break;
					case NSPresentationIntentKindTableRow:       tableRow = it;                                break;
					case NSPresentationIntentKindTableCell:      tableCell = it;                               break;
					case NSPresentationIntentKindThematicBreak:  thematicBreak = true;                         break;
					default:                                                                                   break;
				}
			}
			identity = intent ? intent.identity : NSNotFound;
		}

		NSInteger identity = NSNotFound;
		NSInteger headerLevel = 0;
		NSInteger quoteDepth = 0;
		NSInteger listDepth = 0;
		NSPresentationIntent* list = nil;
		NSPresentationIntent* listItem = nil;
		NSPresentationIntent* codeBlock = nil;
		NSPresentationIntent* table = nil;
		NSPresentationIntent* tableRow = nil;
		NSPresentationIntent* tableCell = nil;
		bool headerRow = false;
		bool thematicBreak = false;
	};

	struct renderer_t
	{
		renderer_t (OakMarkdownStyle* style, NSAttributedString*(^footer)(NSUInteger)) : style(style), footer(footer)
		{
			output     = [[NSMutableAttributedString alloc] init];
			codeBlocks = [NSMutableArray array];
			tables     = [NSMutableDictionary dictionary];
			tableRows  = [NSMutableDictionary dictionary];
		}

		void append_run (NSString* text, NSDictionary* attributes)
		{
			block_info_t block(attributes[NSPresentationIntentAttributeName]);
			droppedPrefix = 0;

			if(block.identity != lastIdentity)
			{
				// GitHub task list items: Foundation’s parser leaves “[ ] ” / “[x] ” in the text
				taskState = kNotATask;
				if(block.listItem && block.listItem.identity != lastListItemIdentity && text.length >= 4 && [text characterAtIndex:0] == '[' && [text characterAtIndex:2] == ']' && [text characterAtIndex:3] == ' ')
				{
					unichar mark = [text characterAtIndex:1];
					if(mark == ' ' || mark == 'x' || mark == 'X')
					{
						taskState = mark == ' ' ? kTaskOpen : kTaskDone;
						text = [text substringFromIndex:4];
						droppedPrefix = 4;
					}
				}

				finish_code_block_if_needed(block);
				if(output.length)
					append(@"\n", @{ NSParagraphStyleAttributeName: paragraphStyle });
				begin_block(block);
				lastIdentity = block.identity;
			}

			textStart = output.length;
			if(block.thematicBreak)
				return append(@" ", @{ NSParagraphStyleAttributeName: paragraphStyle, NSFontAttributeName: [NSFont systemFontOfSize:1] });

			if(NSURL* imageURL = attributes[NSImageURLAttributeName])
				return append_image(imageURL, text, inline_attributes(attributes, block));

			if(block.codeBlock)
			{
				// The parser includes the fence’s trailing newline; we add our own separators
				if([text hasSuffix:@"\n"])
					text = [text substringToIndex:text.length - 1];
				[currentCode appendString:text];
			}

			append(text, inline_attributes(attributes, block));
		}

		NSUInteger length () const
		{
			return output.length;
		}

		// For the last run: where its text starts in the output, after
		// separators and list markers, and how much of its start was dropped
		NSUInteger textStart     = 0;
		NSUInteger droppedPrefix = 0;

		NSMutableAttributedString* finish ()
		{
			finish_code_block_if_needed(block_info_t(nil));
			return output;
		}

		NSMutableArray<OakMarkdownCodeBlock*>* codeBlocks;

	private:
		enum task_state_t { kNotATask, kTaskOpen, kTaskDone };

		void append (NSString* text, NSDictionary* attributes)
		{
			[output appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
		}

		void append_image (NSURL* url, NSString* alt, NSDictionary* attributes)
		{
			url = url.absoluteURL;
			alt = [alt stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""]; // the parser’s text for an image without alt text
			NSImage* image = url.isFileURL ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
			if(!image || image.size.width <= 0 || image.size.height <= 0)
			{
				// Remote images aren’t fetched, so previewing a document doesn’t reach out to the network
				NSMutableDictionary* res = [attributes mutableCopy];
				res[NSLinkAttributeName]            = url;
				res[NSForegroundColorAttributeName] = style.secondaryTextColor;
				return append([NSString stringWithFormat:@"[%@]", alt.length ? alt : (url.lastPathComponent ?: @"image")], res);
			}

			NSSize size = image.size;
			if(style.maximumImageWidth > 0 && size.width > style.maximumImageWidth)
				size = NSMakeSize(style.maximumImageWidth, round(size.height * style.maximumImageWidth / size.width));

			NSTextAttachment* attachment = [[NSTextAttachment alloc] init];
			attachment.image  = image;
			attachment.bounds = NSMakeRect(0, 0, size.width, size.height);

			NSMutableAttributedString* str = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
			[str addAttributes:attributes range:NSMakeRange(0, str.length)];
			if(alt.length)
				[str addAttribute:NSToolTipAttributeName value:alt range:NSMakeRange(0, str.length)];
			[output appendAttributedString:str];
		}

		void begin_block (block_info_t const& block)
		{
			NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
			paragraph.paragraphSpacing = 6;

			CGFloat indent = block.quoteDepth * kQuoteIndent;
			NSString* prefix = nil;

			if(block.listItem)
			{
				indent += block.listDepth * kListIndent;
				paragraph.paragraphSpacing = 3;
				if(block.listItem.identity != lastListItemIdentity)
				{
					lastListItemIdentity = block.listItem.identity;
					if(taskState != kNotATask)
						prefix = taskState == kTaskDone ? @"☑\t" : @"☐\t";
					else if(block.list.intentKind == NSPresentationIntentKindOrderedList)
						prefix = [NSString stringWithFormat:@"%ld.\t", block.listItem.ordinal];
					else	prefix = @"•\t";
					paragraph.firstLineHeadIndent = indent - kListIndent;
				}
				else
				{
					paragraph.firstLineHeadIndent = indent; // further paragraphs of the same item
				}
				paragraph.tabStops = @[ [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:indent options:@{ }] ];
				paragraph.headIndent = indent;
			}
			else
			{
				paragraph.firstLineHeadIndent = indent;
				paragraph.headIndent          = indent;
			}

			if(block.headerLevel)
			{
				paragraph.paragraphSpacingBefore = 6;
				paragraph.paragraphSpacing       = 4;
			}

			if(block.codeBlock && block.codeBlock.identity != currentCodeIdentity)
			{
				currentCodeIdentity = block.codeBlock.identity;
				currentCode         = [NSMutableString string];
				currentLanguage     = block.codeBlock.languageHint.length ? block.codeBlock.languageHint : nil;

				codeTextBlock = [[NSTextBlock alloc] init];
				codeTextBlock.backgroundColor = style.codeBackgroundColor;
				[codeTextBlock setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
				[codeTextBlock setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
				[codeTextBlock setWidth:4 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinYEdge];
				[codeTextBlock setWidth:4 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMaxYEdge];
				[codeTextBlock setWidth:indent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
			}

			if(block.codeBlock)
			{
				paragraph.textBlocks       = @[ codeTextBlock ];
				paragraph.firstLineHeadIndent = 0;
				paragraph.headIndent       = 0;
				paragraph.paragraphSpacing = 0;
			}
			else if(block.quoteDepth && !block.listItem)
			{
				NSTextBlock* quote = [[NSTextBlock alloc] init];
				[quote setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth]; // without a width the block collapses to one character per line
				[quote setWidth:3 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder edge:NSMinXEdge];
				[quote setBorderColor:style.borderColor forEdge:NSMinXEdge];
				[quote setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMinXEdge];
				[quote setWidth:(block.quoteDepth - 1) * kQuoteIndent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
				paragraph.textBlocks          = @[ quote ];
				paragraph.firstLineHeadIndent = 0;
				paragraph.headIndent          = 0;
			}

			if(block.tableCell)
			{
				NSNumber* tableKey = @(block.table.identity);
				NSTextTable* table = tables[tableKey];
				if(!table)
				{
					table = [[NSTextTable alloc] init];
					table.numberOfColumns = MAX(block.table.columnCount, 1);
					table.layoutAlgorithm = NSTextTableAutomaticLayoutAlgorithm;
					table.collapsesBorders = YES;
					tables[tableKey] = table;
				}

				// Row index by order of appearance, so it doesn’t matter how the parser numbers rows
				NSMutableArray* rows = tableRows[tableKey] ?: (tableRows[tableKey] = [NSMutableArray array]);
				if(![rows containsObject:@(block.tableRow.identity)])
					[rows addObject:@(block.tableRow.identity)];
				NSInteger row = [rows indexOfObject:@(block.tableRow.identity)];

				NSTextTableBlock* cell = [[NSTextTableBlock alloc] initWithTable:table startingRow:row rowSpan:1 startingColumn:block.tableCell.column columnSpan:1];
				[cell setWidth:0.5 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder];
				[cell setBorderColor:style.borderColor];
				[cell setWidth:4 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
				paragraph.textBlocks          = @[ cell ];
				paragraph.firstLineHeadIndent = 0;
				paragraph.headIndent          = 0;
				paragraph.paragraphSpacing    = 0;
			}

			if(block.thematicBreak)
			{
				// A full-width line: the bottom border of an (almost) empty block
				NSTextBlock* rule = [[NSTextBlock alloc] init];
				[rule setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
				[rule setWidth:1 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder edge:NSMaxYEdge];
				[rule setBorderColor:style.borderColor forEdge:NSMaxYEdge];
				[rule setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinYEdge];
				[rule setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMaxYEdge];
				[rule setWidth:indent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
				paragraph.textBlocks          = @[ rule ];
				paragraph.firstLineHeadIndent = 0;
				paragraph.headIndent          = 0;
				paragraph.paragraphSpacing    = 0;
			}

			paragraphStyle = paragraph;
			if(prefix)
				append(prefix, @{ NSParagraphStyleAttributeName: paragraph, NSForegroundColorAttributeName: style.textColor, NSFontAttributeName: style.font });
		}

		void finish_code_block_if_needed (block_info_t const& next)
		{
			if(!currentCode || (next.codeBlock && next.codeBlock.identity == currentCodeIdentity))
				return;

			OakMarkdownCodeBlock* codeBlock = [[OakMarkdownCodeBlock alloc] init];
			codeBlock.code     = currentCode;
			codeBlock.language = currentLanguage;
			[codeBlocks addObject:codeBlock];

			if(footer)
			{
				if(NSAttributedString* str = footer(codeBlocks.count - 1))
				{
					NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
					paragraph.paragraphSpacing = 6;
					paragraph.firstLineHeadIndent = paragraph.headIndent = paragraphStyle.headIndent;
					append(@"\n", @{ NSParagraphStyleAttributeName: paragraphStyle });
					NSMutableAttributedString* footerString = [str mutableCopy];
					[footerString addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, footerString.length)];
					[output appendAttributedString:footerString];
					paragraphStyle = paragraph;
				}
			}

			currentCode         = nil;
			currentLanguage     = nil;
			currentCodeIdentity = NSNotFound;
		}

		NSDictionary* inline_attributes (NSDictionary* attributes, block_info_t const& block)
		{
			NSUInteger inlineIntent = [attributes[NSInlinePresentationIntentAttributeName] unsignedIntegerValue];

			NSFont* font = style.font;
			if(block.codeBlock || (inlineIntent & NSInlinePresentationIntentCode))
				font = style.codeFont;
			if(block.headerLevel)
				font = [NSFont systemFontOfSize:style.font.pointSize + std::max<NSInteger>(0, 8 - 2 * block.headerLevel) weight:NSFontWeightSemibold];
			if((inlineIntent & NSInlinePresentationIntentStronglyEmphasized) || block.headerRow)
				font = FontWithTrait(font, NSFontDescriptorTraitBold);
			if(inlineIntent & NSInlinePresentationIntentEmphasized)
				font = FontWithTrait(font, NSFontDescriptorTraitItalic);

			NSMutableDictionary* res = [NSMutableDictionary dictionaryWithDictionary:@{
				NSFontAttributeName:            font,
				NSForegroundColorAttributeName: block.quoteDepth ? style.secondaryTextColor : style.textColor,
				NSParagraphStyleAttributeName:  paragraphStyle,
			}];

			if(block.codeBlock)
				res[OakMarkdownCodeBlockAttributeName] = @(codeBlocks.count);
			else if(inlineIntent & NSInlinePresentationIntentCode)
				res[NSBackgroundColorAttributeName] = style.codeBackgroundColor;
			if(inlineIntent & NSInlinePresentationIntentStrikethrough)
				res[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
			if(id link = attributes[NSLinkAttributeName])
				res[NSLinkAttributeName] = [link isKindOfClass:[NSURL class]] ? [(NSURL*)link absoluteURL] : link; // relative links resolved against the base URL
			return res;
		}

		OakMarkdownStyle* style;
		NSAttributedString*(^footer)(NSUInteger);
		NSMutableAttributedString* output;
		NSParagraphStyle* paragraphStyle = [NSParagraphStyle defaultParagraphStyle];

		task_state_t taskState         = kNotATask;
		NSInteger lastIdentity         = NSNotFound - 1;
		NSInteger lastListItemIdentity = NSNotFound;

		NSInteger currentCodeIdentity = NSNotFound;
		NSMutableString* currentCode;
		NSString* currentLanguage;
		NSTextBlock* codeTextBlock;

		NSMutableDictionary<NSNumber*, NSTextTable*>* tables;
		NSMutableDictionary<NSNumber*, NSMutableArray*>* tableRows;
	};

	// =============
	// = Footnotes =
	// =============

	// Foundation’s parser doesn’t know GitHub’s footnotes, so they’re handled
	// around it: references become markers (private use characters around a
	// kind and a number), definitions are taken out, and after rendering the
	// markers become superscript links and the definitions a numbered list.

	enum marker_kind_t : unichar { kFootnoteReference = 'r', kFootnoteStart = 'd', kFootnoteBackReference = 'b' };

	NSString* Marker (marker_kind_t kind, NSUInteger number)
	{
		return [NSString stringWithFormat:@"%C%lu", (unichar)kind, number];
	}

	bool IsBlank (NSString* line)
	{
		return [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length == 0;
	}

	bool IsIndented (NSString* line)
	{
		return [line hasPrefix:@"    "] || [line hasPrefix:@"\t"];
	}

	NSString* Dedent (NSString* line)
	{
		return [line hasPrefix:@"\t"] ? [line substringFromIndex:1] : [line hasPrefix:@"    "] ? [line substringFromIndex:4] : line;
	}

	// The fence (e.g. “```”) if the line opens or closes a fenced code block
	NSString* Fence (NSString* line)
	{
		static NSRegularExpression* const regex = [NSRegularExpression regularExpressionWithPattern:@"^ {0,3}(`{3,}|~{3,})" options:0 error:nil];
		NSTextCheckingResult* match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
		return match ? [line substringWithRange:[match rangeAtIndex:1]] : nil;
	}

	struct footnotes_t
	{
		// Returns the Markdown with references replaced by markers and
		// definitions by empty lines, so source line numbers don’t change
		NSString* extract (NSString* markdown)
		{
			static NSRegularExpression* const definitionRegex = [NSRegularExpression regularExpressionWithPattern:@"^ {0,3}\\[\\^([^\\]\\s]+)\\]:[ \\t]?(.*)$" options:0 error:nil];

			NSMutableArray<NSString*>* lines = [[markdown componentsSeparatedByString:@"\n"] mutableCopy];
			std::vector<bool> skip(lines.count, false); // code and definitions

			NSString* fence = nil;
			NSMutableString* definition = nil; // being read
			bool lazy = false;                 // the previous line was definition text, so a plain line continues it
			for(NSUInteger i = 0; i < lines.count; ++i)
			{
				NSString* line = lines[i];
				if(fence)
				{
					skip[i] = true;
					NSString* closing = Fence(line);
					if(closing && [closing characterAtIndex:0] == [fence characterAtIndex:0] && closing.length >= fence.length && IsBlank([line substringFromIndex:NSMaxRange([line rangeOfString:closing])]))
						fence = nil;
					continue;
				}

				NSTextCheckingResult* match = [definitionRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
				if(definition && !match)
				{
					if(IsBlank(line))
					{
						// Blank lines belong to the definition if indented text follows
						NSUInteger next = i;
						while(next < lines.count && IsBlank(lines[next]))
							++next;
						if(next < lines.count && IsIndented(lines[next]))
						{
							for(; i < next; ++i)
							{
								[definition appendString:@"\n"];
								lines[i] = @"";
								skip[i] = true;
							}
							--i;
							lazy = false;
							continue;
						}
					}
					else if(IsIndented(line) || (lazy && !Fence(line)))
					{
						[definition appendFormat:@"\n%@", Dedent(line)];
						lines[i] = @"";
						skip[i] = true;
						lazy = !IsIndented(line) || !IsBlank(Dedent(line));
						continue;
					}
					definition = nil;
				}

				if(match)
				{
					NSString* label = [line substringWithRange:[match rangeAtIndex:1]].lowercaseString;
					definition = [[line substringWithRange:[match rangeAtIndex:2]] mutableCopy];
					if(!definitions[label]) // the first definition wins
						definitions[label] = definition;
					lines[i] = @"";
					skip[i]  = true;
					lazy     = true;
				}
				else if((fence = Fence(line)))
				{
					skip[i] = true;
				}
			}

			for(NSUInteger i = 0; i < lines.count; ++i)
			{
				if(!skip[i] && [lines[i] containsString:@"[^"])
					lines[i] = replace_references(lines[i]);
			}
			return [lines componentsJoinedByString:@"\n"];
		}

		// Referenced definitions, in the order of their first reference
		NSArray<NSString*>* notes () const
		{
			return order;
		}

	private:
		// `[^label]` with a definition becomes a marker; code spans and escaped brackets are left alone
		NSString* replace_references (NSString* line)
		{
			NSMutableString* res = [NSMutableString string];
			NSUInteger const length = line.length;
			for(NSUInteger i = 0; i < length; )
			{
				unichar ch = [line characterAtIndex:i];
				if(ch == '\\' && i + 1 < length)
				{
					[res appendString:[line substringWithRange:NSMakeRange(i, 2)]];
					i += 2;
					continue;
				}

				if(ch == '`')
				{
					NSUInteger run = i;
					while(run < length && [line characterAtIndex:run] == '`')
						++run;
					NSString* ticks = [line substringWithRange:NSMakeRange(i, run - i)];

					// The closing run of exactly as many backticks
					NSUInteger end = NSNotFound;
					for(NSRange range = NSMakeRange(run, length - run); range.length; )
					{
						NSRange found = [line rangeOfString:ticks options:0 range:range];
						if(found.location == NSNotFound)
							break;
						NSUInteger after = NSMaxRange(found);
						while(after < length && [line characterAtIndex:after] == '`')
							++after;
						if(after == NSMaxRange(found))
						{
							end = after;
							break;
						}
						range = NSMakeRange(after, length - after);
					}

					NSUInteger stop = end != NSNotFound ? end : run;
					[res appendString:[line substringWithRange:NSMakeRange(i, stop - i)]];
					i = stop;
					continue;
				}

				if(ch == '[' && i + 1 < length && [line characterAtIndex:i+1] == '^')
				{
					NSRange close = [line rangeOfString:@"]" options:0 range:NSMakeRange(i + 2, length - i - 2)];
					if(close.location != NSNotFound && close.location > i + 2)
					{
						NSString* label = [line substringWithRange:NSMakeRange(i + 2, close.location - i - 2)].lowercaseString;
						if(NSString* note = [label rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound ? definitions[label] : nil)
						{
							NSNumber* number = numbers[label];
							if(!number)
							{
								[order addObject:note];
								number = numbers[label] = @(order.count);
							}
							[res appendString:Marker(kFootnoteReference, number.unsignedIntegerValue)];
							i = NSMaxRange(close);
							continue;
						}
					}
				}

				[res appendFormat:@"%C", ch];
				++i;
			}
			return res;
		}

		NSMutableDictionary<NSString*, NSMutableString*>* definitions = [NSMutableDictionary dictionary];
		NSMutableDictionary<NSString*, NSNumber*>* numbers = [NSMutableDictionary dictionary];
		NSMutableArray<NSString*>* order = [NSMutableArray array];
	};

	// Markdown for the notes: a rule, then a numbered list. Each item starts
	// with a marker for its anchor and ends with one for the link back.
	NSString* FootnotesMarkdown (NSArray<NSString*>* notes)
	{
		NSMutableString* res = [NSMutableString stringWithString:@"---\n\n"];
		[notes enumerateObjectsUsingBlock:^(NSString* note, NSUInteger index, BOOL* stop){
			NSMutableArray<NSString*>* lines = [[note componentsSeparatedByString:@"\n"] mutableCopy];
			while(lines.count > 1 && IsBlank(lines.lastObject))
				[lines removeLastObject];
			for(NSUInteger i = 1; i < lines.count; ++i)
				lines[i] = IsBlank(lines[i]) ? @"" : [@"   " stringByAppendingString:lines[i]];
			lines[lines.count - 1] = [lines.lastObject stringByAppendingFormat:@" %@", Marker(kFootnoteBackReference, index + 1)];
			[res appendFormat:@"%lu. %@%@\n", index + 1, Marker(kFootnoteStart, index + 1), [lines componentsJoinedByString:@"\n"]];
		}];
		return res;
	}

	NSURL* FootnoteURL (NSString* anchor, NSURL* baseURL)
	{
		NSURL* url = [NSURL URLWithString:[@"#" stringByAppendingString:anchor] relativeToURL:baseURL];
		return baseURL ? url.absoluteURL : url;
	}

	// References become superscript numbers linking to their note, the note’s
	// start gets its anchor, and the end of the note a ↩ back to the reference
	void ReplaceFootnoteMarkers (NSMutableAttributedString* str, NSURL* baseURL)
	{
		static NSRegularExpression* const regex = [NSRegularExpression regularExpressionWithPattern:@"\\uE000([rdb])(\\d+)\\uE001" options:0 error:nil];
		NSArray<NSTextCheckingResult*>* matches = [regex matchesInString:str.string options:0 range:NSMakeRange(0, str.length)];

		NSMutableSet<NSString*>* referenced = [NSMutableSet set]; // only the first reference gets the anchor
		std::vector<bool> firstReference(matches.count, false);
		for(NSUInteger i = 0; i < matches.count; ++i)
		{
			NSString* number = [str.string substringWithRange:[matches[i] rangeAtIndex:2]];
			if([[str.string substringWithRange:[matches[i] rangeAtIndex:1]] isEqualToString:@"r"] && ![referenced containsObject:number])
			{
				[referenced addObject:number];
				firstReference[i] = true;
			}
		}

		for(NSUInteger i = matches.count; i-- > 0; )
		{
			NSRange range   = matches[i].range;
			unichar kind    = [str.string characterAtIndex:[matches[i] rangeAtIndex:1].location];
			NSString* number = [str.string substringWithRange:[matches[i] rangeAtIndex:2]];
			NSMutableDictionary* attributes = [[str attributesAtIndex:range.location effectiveRange:nullptr] mutableCopy];

			if(kind == kFootnoteStart)
			{
				[str deleteCharactersInRange:range];
				if(range.location < str.length)
					[str addAttribute:OakMarkdownAnchorAttributeName value:[@"fn-" stringByAppendingString:number] range:NSMakeRange(range.location, 1)];
				continue;
			}

			NSString* text = number;
			if(kind == kFootnoteReference)
			{
				NSFont* font = attributes[NSFontAttributeName] ?: [NSFont systemFontOfSize:NSFont.systemFontSize];
				attributes[NSFontAttributeName]           = [NSFont fontWithDescriptor:font.fontDescriptor size:round(font.pointSize * 0.75)] ?: font;
				attributes[NSBaselineOffsetAttributeName] = @(round(font.pointSize * 0.35));
				attributes[NSLinkAttributeName]           = FootnoteURL([@"fn-" stringByAppendingString:number], baseURL);
				if(firstReference[i])
					attributes[OakMarkdownAnchorAttributeName] = [@"fnref-" stringByAppendingString:number];
			}
			else
			{
				text = @"↩";
				attributes[NSLinkAttributeName] = FootnoteURL([@"fnref-" stringByAppendingString:number], baseURL);
			}
			[str replaceCharactersInRange:range withAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
		}
	}
}

static NSMutableAttributedString* Render (NSString* markdown, OakMarkdownStyle* style, BOOL marksSourceLines, NSURL* baseURL, NSArray<OakMarkdownCodeBlock*>** codeBlocks, NSAttributedString*(^codeBlockFooter)(NSUInteger index))
{
	NSAttributedStringMarkdownParsingOptions* options = [[NSAttributedStringMarkdownParsingOptions alloc] init];
	options.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxFull;
	options.failurePolicy     = NSAttributedStringMarkdownParsingFailureReturnPartiallyParsedIfPossible;
	options.appliesSourcePositionAttributes = marksSourceLines;

	renderer_t renderer(style, codeBlockFooter);
	renderer_t* rendererPtr = &renderer; // blocks would capture the C++ object by copy

	NSAttributedString* parsed = [[NSAttributedString alloc] initWithMarkdownString:markdown options:options baseURL:baseURL error:nil];
	if(!parsed)
	{
		if(codeBlocks)
			*codeBlocks = @[ ];
		return [[NSMutableAttributedString alloc] initWithString:markdown attributes:@{ NSFontAttributeName: style.font, NSForegroundColorAttributeName: style.textColor }];
	}

	// Source positions split the text into many small runs; take them out so
	// the renderer sees the same runs as without them
	std::vector<std::pair<NSUInteger, NSInteger>> sourceLines; // parsed index → line
	if(marksSourceLines)
	{
		NSMutableAttributedString* stripped = [parsed mutableCopy];
		auto sourceLinesPtr = &sourceLines;
		[parsed enumerateAttribute:NSMarkdownSourcePositionAttributeName inRange:NSMakeRange(0, parsed.length) options:0 usingBlock:^(NSAttributedStringMarkdownSourcePosition* position, NSRange range, BOOL* stop){
			if(position && (sourceLinesPtr->empty() || position.startLine > sourceLinesPtr->back().second))
				sourceLinesPtr->emplace_back(range.location, position.startLine);
		}];
		[stripped removeAttribute:NSMarkdownSourcePositionAttributeName range:NSMakeRange(0, stripped.length)];
		parsed = stripped;
	}

	// Where each run of the parsed string ended up in the output
	struct run_t { NSRange parsed; NSUInteger textStart; NSUInteger droppedPrefix; NSUInteger outputEnd; };
	std::vector<run_t> runs;
	auto runsPtr = &runs;
	[parsed enumerateAttributesInRange:NSMakeRange(0, parsed.length) options:0 usingBlock:^(NSDictionary<NSAttributedStringKey, id>* attributes, NSRange range, BOOL* stop){
		rendererPtr->append_run([parsed.string substringWithRange:range], attributes);
		runsPtr->push_back({ range, rendererPtr->textStart, rendererPtr->droppedPrefix, rendererPtr->length() });
	}];

	NSMutableAttributedString* res = renderer.finish();
	auto run = runs.begin();
	for(auto const& [index, line] : sourceLines)
	{
		while(run != runs.end() && NSMaxRange(run->parsed) <= index)
			++run;
		if(run == runs.end())
			break;

		NSUInteger offset = index - run->parsed.location;
		NSUInteger outputIndex = run->textStart + (offset > run->droppedPrefix ? offset - run->droppedPrefix : 0);
		if(outputIndex < MIN(run->outputEnd, res.length))
			[res addAttribute:OakMarkdownSourceLineAttributeName value:@(line) range:NSMakeRange(outputIndex, 1)];
	}

	if(codeBlocks)
		*codeBlocks = [renderer.codeBlocks copy];
	return res;
}

@implementation OakMarkdownRenderer
+ (NSAttributedString*)attributedStringFromMarkdown:(NSString*)markdown style:(OakMarkdownStyle*)style codeBlocks:(NSArray<OakMarkdownCodeBlock*>**)codeBlocks codeBlockFooter:(NSAttributedString*(^)(NSUInteger index))codeBlockFooter
{
	return [self attributedStringFromMarkdown:markdown style:style baseURL:nil codeBlocks:codeBlocks codeBlockFooter:codeBlockFooter];
}

+ (NSAttributedString*)attributedStringFromMarkdown:(NSString*)markdown style:(OakMarkdownStyle*)style baseURL:(NSURL*)baseURL codeBlocks:(NSArray<OakMarkdownCodeBlock*>**)codeBlocks codeBlockFooter:(NSAttributedString*(^)(NSUInteger index))codeBlockFooter
{
	style = style ?: [OakMarkdownStyle defaultStyle];

	footnotes_t footnotes;
	NSString* text = [markdown containsString:@"[^"] ? footnotes.extract(markdown) : markdown;
	NSMutableAttributedString* res = Render(text, style, style.marksSourceLines, baseURL, codeBlocks, codeBlockFooter);
	if(!footnotes.notes().count)
		return res;

	// The notes come last, without source lines (they aren’t where they were
	// written) or code block indices (they aren’t in `codeBlocks`)
	NSMutableAttributedString* notes = Render(FootnotesMarkdown(footnotes.notes()), style, NO, baseURL, nullptr, nil);
	[notes removeAttribute:OakMarkdownCodeBlockAttributeName range:NSMakeRange(0, notes.length)];
	if(res.length)
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:[res attributesAtIndex:res.length - 1 effectiveRange:nullptr]]];
	[res appendAttributedString:notes];

	ReplaceFootnoteMarkers(res, baseURL);
	return res;
}
@end
