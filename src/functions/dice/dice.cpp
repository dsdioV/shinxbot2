#include "dice.h"
#include "utils.h"
#include <regex>
#include <random>
#include <sstream>

void dice::process(std::string message, const msg_meta &conf) {

    static const std::regex dice_regex(R"(\b(\d{0,3})[dD](\d{1,3})\b)");
    static thread_local std::mt19937 rng(std::random_device{}());

    auto words_begin = std::sregex_iterator(message.begin(), message.end(), dice_regex);
    auto words_end = std::sregex_iterator();

    std::ostringstream oss;
    bool first = true;
    int match_count = 0;

    for (std::sregex_iterator i = words_begin; i != words_end; ++i) {
        std::smatch match = *i;
        std::string num_str = match[1].str();
        std::string side_str = match[2].str();


        int num = num_str.empty() ? 1 : std::stoi(num_str);
        if (num <= 0) num = 1;
        

        int sides = std::stoi(side_str);
        if (sides <= 0) continue; // 忽略0面骰子

        if (!first) oss << "\n";
        first = false;
        match_count++;

        std::vector<int> rolls;
        long long total = 0;
        std::uniform_int_distribution<int> dist(1, sides);

        for (int n = 0; n < num; ++n) {
            int r = dist(rng);
            rolls.push_back(r);
            total += r;
        }


        oss << match.str() << ": " << total;
        if (num > 1) {
            oss << " [";
            for (size_t j = 0; j < rolls.size(); ++j) {
                oss << rolls[j] << (j == rolls.size() - 1 ? "" : "+");

                if (oss.tellp() > 4000) {
                    oss << "...";
                    break;
                }
            }
            oss << "]";
        }
        

        if (match_count >= 10) break;
    }

    if (match_count > 0) {
        std::string reply = "[CQ:reply,id=" + std::to_string(conf.message_id) + "]" + oss.str();
        conf.p->cq_send(reply, conf);
        conf.p->setlog(LOG::INFO, "dice_module: user " + std::to_string(conf.user_id) + " rolled " + std::to_string(match_count) + " times");
    }
}

bool dice::check(std::string message, const msg_meta &conf) {
    (void)conf;
    static const std::regex dice_search_regex(R"(\b(\d{0,3})[dD](\d{1,3})\b)");
    return std::regex_search(message, dice_search_regex);
}

std::string dice::help() {
    return "骰子投掷：输入 [数量]d[面数]（如 3d6, d20）进行投掷，支持多重匹配";
}

DECLARE_FACTORY_FUNCTIONS(dice)
