import Foundation

// MARK: - 拼音音节表
//
// 新增文件，被小鹤双拼模块与拼音合法性判定共用：
//   - 小鹤双拼：把合法音节编码成两键双拼码，用于双拼码展开成全拼
//
// 约定：不带声调，ü 统一写作 v（如 lv / nve），j/q/x/y 后的 ü 仍写作 u（如 ju / que）。

public enum PinyinSyllables {

    /// 全部合法拼音音节（约 410 个，覆盖常用字全部读音）
    public static let all: [String] = """
    a ai an ang ao
    ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
    ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
    da dai dan dang dao de dei deng di dia dian diao die ding diu dong dou du duan dui dun duo
    e ei en eng er
    fa fan fang fei fen feng fo fou fu
    ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
    ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
    ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
    ka kai kan kang kao ke ken keng kong kou ku kua kuai kuan kuang kui kun kuo
    la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu long lou lu luan lun luo lv lve
    ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
    na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nv nve
    o ou
    pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
    qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
    ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
    sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
    ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
    wa wai wan wang wei wen weng wo wu
    xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
    ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
    za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
    """
    .split(whereSeparator: { $0.isWhitespace })
    .map(String.init)

    // MARK: - 合法拼音前缀判定

    /// 音节集合（完整音节查找用）
    private static let syllableSet: Set<String> = Set(all)
    /// 音节的所有真前缀（「最后一个音节还没敲完」的判定用）
    private static let syllablePrefixes: Set<String> = {
        var prefixes = Set<String>()
        for syllable in all {
            for end in 1..<syllable.count { prefixes.insert(String(syllable.prefix(end))) }
        }
        return prefixes
    }()
    /// 最长音节长度（由音节表算出，不写死）
    private static let maxSyllableLength = all.map { $0.count }.max() ?? 1

    /// 这串字母是否是合法的拼音连写前缀：能切成若干完整音节，末尾允许停在某个音节的半途。
    ///
    /// 混打时用它给音码参与方案守门：主方案是形码时用户敲的是形码串（虎码 lc），
    /// 而音码检索自带「去尾一字符再查」的部分回退，lc 会被退化成 l 并把 l 开头的一整批
    /// 无关候选混进来。判定放在混打的参与方案这一层，主方案（含 26 键打错字母的容错）语义不动。
    public static func isValidPinyinPrefix(_ input: String) -> Bool {
        let lowered = input.lowercased()
        guard !lowered.isEmpty,
              lowered.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        let chars = Array(lowered)
        let count = chars.count

        // reachable[i]：前 i 个字符能切成若干完整音节
        var reachable = [Bool](repeating: false, count: count + 1)
        reachable[0] = true
        for i in 0..<count where reachable[i] {
            for len in 1...min(maxSyllableLength, count - i)
            where syllableSet.contains(String(chars[i..<(i + len)])) {
                reachable[i + len] = true
            }
        }
        if reachable[count] { return true }

        // 整串切不完时，看剩下的尾巴是不是某个音节的半途（正在打的最后一个音节）
        for i in (0..<count).reversed() where reachable[i] {
            if syllablePrefixes.contains(String(chars[i..<count])) { return true }
        }
        return false
    }
}
